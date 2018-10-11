package Plugins::YouTube::ProtocolHandler;

# (c) 2018, philippe_44@outlook.com
#
# Released under GPLv2
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

use base qw(IO::Handle);

use strict;

use List::Util qw(min max first);
use HTML::Parser;
use HTTP::Date;
use URI;
use URI::Escape;
use Scalar::Util qw(blessed);
use JSON::XS;
use Data::Dumper;
use File::Spec::Functions;
use FindBin qw($Bin);
use XML::Simple;

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::YouTube::Signature;
use Plugins::YouTube::WebM;
use Plugins::YouTube::M4a;

use constant MIN_OUT	=> 8192;
use constant DATA_CHUNK => 128*1024;	

my $log   = logger('plugin.youtube');
my $prefs = preferences('plugin.youtube');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('youtube', __PACKAGE__);

sub flushCache { $cache->cleanup(); }

=comment
There is a voluntaty 'confusion' between codecs and streaming formats 
(regular http or dash). As we only support ogg with webm and aac with
dash, this is not a problem at this point, although not very elegant.
This only works because it seems that YT, when using webm and dash (171)
does not build a mpd file but instead uses regular webm. It might be due
to http://wiki.webmproject.org/adaptive-streaming/webm-dash-specification
but I'm not sure at that point. Anyway, the dash webm format used in codec 
171, probably because there is a single stream, does not need a different
handling than normal webm
=cut

my $getProperties  = { 'ogg' => \&Plugins::YouTube::WebM::getProperties, 'aac' => \&Plugins::YouTube::M4a::getProperties };
my $getAudio 	   = { 'ogg' => \&Plugins::YouTube::WebM::getAudio, 'aac' => \&Plugins::YouTube::M4a::getAudio };
my $getStartOffset = { 'ogg' => \&Plugins::YouTube::WebM::getStartOffset, 'aac' => \&Plugins::YouTube::M4a::getStartOffset };

sub canDoAction {
    my ( $class, $client, $url, $action ) = @_;
    
	main::INFOLOG && $log->is_info && $log->info( "action=$action" );
	
	# if restart, restart from beginning (stop being live edge)
	$client->playingSong()->pluginData('props')->{'liveOffset'} = 0 if $action eq 'rew' && $client->isPlaying(1);
		
	return 1;
}


sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my $offset;
	my $props = $song->pluginData('props');
	
	return undef if !defined $props;
	
	main::DEBUGLOG && $log->is_debug && $log->debug( Dumper($props) );
	
	# set offset depending on format
	$offset = $props->{'liveOffset'} if $props->{'liveOffset'};
	$offset = $props->{offset}->{clusters} if $props->{offset}->{clusters}; 
						
	$args->{'url'} = $song->pluginData('baseURL');
	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'};
  
	if ($startTime) {
		$song->can('startOffset') ? $song->startOffset($startTime) : ($song->{startOffset} = $startTime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $startTime);
		$offset = 0;
	}
	
	main::INFOLOG && $log->is_info && $log->info("url: $args->{url}");
	
	my $self = $class->SUPER::new;
	
	if (defined($self)) {
		${*$self}{'client'} = $args->{'client'};
		${*$self}{'song'}   = $args->{'song'};
		${*$self}{'url'}    = $args->{'url'};
		${*$self}{'props'}  = $props;		
		${*$self}{'vars'}   = {        		# variables which hold state for this instance:
			'inBuf'       => '',      		# buffer of received data
			'outBuf'      => '',      		# buffer of processed audio
			'streaming'   => 1,      		# flag for streaming, changes to 0 when all data received
			'fetching'    => 0,		  		# waiting for HTTP data
			'offset'      => $offset,  		# offset for next HTTP request in webm/stream or segment index in dash
		};
	}
	
	# set starting offset (bytes or index, depending on streaming format)
	$getStartOffset->{$props->{'format'}}($args->{url}, $startTime, $props, sub { ${*$self}{'vars'}->{offset} = shift }) if !$offset;
	
	# set timer for updating the MPD if needed (dash)
	${*$self}{'active'}  = 1;		
	Slim::Utils::Timers::setTimer($self, time() + $props->{'updatePeriod'}, \&updateMPD) if $props->{'updatePeriod'};
	
	# for live stream, always set duration to timeshift depth
	if ($props->{'timeShiftDepth'}) {
		# only set offset when missing startTime or not starting from live edge
		$song->startOffset($props->{'timeShiftDepth'} - $prefs->get('live_delay')) unless $startTime || !$props->{'liveOffset'};
		$song->duration($props->{'timeShiftDepth'});
		$props->{'startOffset'} = $song->startOffset;
	}	
	
	return $self;
}

sub close {
	my $self = shift;
	
	${*$self}{'active'} = 0;		
	
	if (${*$self}{'props'}->{'updatePeriod'}) {
		main::INFOLOG && $log->is_info && $log->info("killing MPD update timer");
		Slim::Utils::Timers::killTimers($self, \&updateMPD);
	}	
	
	$self->SUPER::close(@_);
}

sub formatOverride { 
	return $_[1]->pluginData('props')->{'format'};
}

sub contentType { 
	return ${*{$_[0]}}{'props'}->{'format'};
}

sub isAudio { 1 }

sub isRemote { 1 }

sub canDirectStream { 0 }

sub songBytes {}

sub canSeek { 1 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

sub vars {
	return ${*{$_[0]}}{'vars'};
}

my $nextWarning = 0;

sub sysread {
	use bytes;

	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];
	my $v = $self->vars;
	my $baseURL = ${*$self}{'url'};
	my $props = ${*$self}{'props'};
	
	$v->{'offset'} ||= 0;
		
	if (!$v->{'fetching'} && !$v->{'init'} && $props->{'initializeURL'}) {
	
		$v->{'fetching'} = 1;
		$v->{'init'} = 1;
		
		main::INFOLOG && $log->is_info && $log->info("fetching initialization URL $baseURL$props->{'initializeURL'}");
		
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$v->{'inBuf'} = $_[0]->content;
				$v->{'fetching'} = 0;
			},

			sub {
				$log->warn("error fetching initialization for $baseURL");
				$v->{'fetching'} = 0;
			}, 
			
		)->get($baseURL . $props->{'initializeURL'});
	}	
		
	# need more data
	$log->error("f:$v->{'fetching'} v:$v->{'streaming'}");
	if ( length $v->{'outBuf'} < MIN_OUT && !$v->{'fetching'} && $v->{'streaming'} ) {
		my $url = $baseURL;
		my @range;
						
		if ( $props->{'segmentURL'} ) {
			$url .= ${$props->{'segmentURL'}}[$v->{'offset'}]->{'media'};		
			$v->{'offset'}++;
		} else {
			@range = ( 'Range', "bytes=$v->{offset}-" . ($v->{offset} + DATA_CHUNK - 1) );
			$v->{offset} += DATA_CHUNK;
		}	
				
		$v->{'fetching'} = 1;
				
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$v->{'inBuf'} .= $_[0]->content;
				$v->{'fetching'} = 0;
				if ( $props->{'segmentURL'} ) {
					$v->{'streaming'} = 0 if $v->{'offset'} == @{$props->{'segmentURL'}};
					main::DEBUGLOG && $log->is_debug && $log->debug("got chunk $v->{'offset'} length: ", length $_[0]->content, " for $url");
					$log->error("got chunk $v->{'offset'} length: ", length $_[0]->content, " for $url");
				} else {
					main::DEBUGLOG && $log->is_debug && $log->debug("got chunk length: ", length $_[0]->content, " from ", $v->{offset} - DATA_CHUNK, " for $url");
					$v->{'streaming'} = 0 if length($_[0]->content) < DATA_CHUNK;
				}		
			},

			sub {
				if (main::DEBUGLOG && $log->is_debug) {
					$log->debug("error fetching $url")
				}
				# only log error every x seconds - it's too noisy for regular use
				elsif (time() > $nextWarning) {
					$log->warn("error fetching $url");
					$nextWarning = time() + 10;
				}

				$v->{'inBuf'} = '';
				$v->{'fetching'} = 0;
			}, 
			
		)->get($url, @range);
	}	

	# process all available data	
	$log->error("starting audio process");
	$getAudio->{$props->{'format'}}($v, $props) if length $v->{'inBuf'};
	$log->error("done");
		
	if ( my $bytes = min(length $v->{'outBuf'}, $maxBytes) ) {
		$_[1] = substr($v->{'outBuf'}, 0, $bytes);
		$v->{'outBuf'} = substr($v->{'outBuf'}, $bytes);
		return $bytes;
	} elsif ( $v->{'streaming'} || $props->{'updatePeriod'} ) {
		$! = EINTR;
		return undef;
	}	
	
	# end of streaming and make sure timer is not running
	main::INFOLOG && $log->is_info && $log->info("end streaming");
	$props->{'updatePeriod'} = 0;
	
	return 0;
}

sub getId {
	my ($class, $url) = @_;

	$url .= '&';
	## also youtube://http://www youtube com/watch?v=tU0_rKD8qjw
		
	if ($url =~ /^(?:youtube:\/\/)?https?:\/\/www\.youtube\.com\/watch\?v=(.*)&/ || 
		$url =~ /^youtube:\/\/www\.youtube\.com\/v\/(.*)&/ ||
		$url =~ /^youtube:\/\/(.*)&/ ||
		$url =~ /([a-zA-Z0-9_\-]+)&/ )
		{
	
		return $1;
	}
	
	return undef;
}

# fetch the YouTube player url and extract a playable stream
sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $masterUrl = $song->track()->url;
	my $id = $class->getId($masterUrl);
	my $url = "http://www.youtube.com/watch?v=$id";
	my @allow = ( [43, 'ogg'], [44, 'ogg'], [45, 'ogg'], [46, 'ogg'] );
	my @allowDASH = ( [171, 'ogg'], [140, 'aac'], [139, 'aac'] );
				  
	main::INFOLOG && $log->is_info && $log->info("next track id: $id url: $url master: $masterUrl");

	# fetch new url(s)
	Slim::Networking::SimpleAsyncHTTP->new(

		sub {
			my $http = shift;
									
			main::DEBUGLOG && $log->is_debug && $log->debug($http->content);
			
			my ($streams) = $http->content =~ /\"url_encoded_fmt_stream_map\":\"(.*?)\"/;
			$streams =~ s/\\u0026/\&/g;
			
			my ($dashmpd) = $http->content =~ /\"dashmpd\":\"(.*?)\"/;
			$dashmpd =~ s/\\u0026/\&/g;
			$dashmpd =~ s/\\//g;
			            			
			main::DEBUGLOG && $log->is_debug && $log->debug($streams);
			
			# first try non-DASH streams;
			main::INFOLOG && $log->is_info && $log->info("trying regular streams");
			my $streamInfo = getStream($streams, \@allow);
			
			# then DASH streams
			if (!$streamInfo) {
				main::INFOLOG && $log->is_info && $log->info("no stream found, trying DASH");
				if ($dashmpd) {
					getMPD($dashmpd, \@allowDASH, sub {
								my $props = shift;
								$song->pluginData(props => $props);
								$song->pluginData(baseURL  => $props->{'baseURL'});
								$getProperties->{$props->{'format'}}($song, $props, $successCb);
							} );
				} else {	
					($streams) = $http->content =~ /\"adaptive_fmts\":\"(.*?)\"/;
					$streams =~ s/\\u0026/\&/g;
					$streamInfo = getStream($streams, \@allowDASH);
				}
			} 	
			
			# process non-DASH streams
			if ($streamInfo) {
					getSignature($http->content, $streamInfo->{'sig'}, $streamInfo->{'encrypted'}, sub {
								my $sig = shift;
								if (defined $sig) {
									my $props = { format => $streamInfo->{'format'} };
									main::DEBUGLOG && $log->is_debug && $log->debug("unobfuscated signature $sig");
									$song->pluginData(props => $props);
									$song->pluginData(baseURL  => $streamInfo->{'url'} . "&signature=" . $sig);
									$getProperties->{$props->{'format'}}($song, $props, $successCb);
								} else {
									$errorCb->();
								}	
							});
			} elsif (!$dashmpd) {
				$log->error("no stream/DASH found ");
				$errorCb->();
			}	

		},
		
		sub {
			$errorCb->($_[1]);
		},		
					
	)->get($url);
}

sub getStream {
	my ($streams, $allow) = @_;
	my $streamInfo;
	my $selected;
			
	for my $stream (split(/,/, $streams)) {
		my $index;
		no strict 'subs';
        my %props = map { $_ =~ /=(.+)/ ? split(/=/, $_) : () } split(/&/, $stream);
				
		main::DEBUGLOG && $log->is_debug && $log->debug($stream);
						
		# check streams in preferred id order
        next unless ($index) = grep { $$allow[$_][0] == $props{itag} } (0 .. @$allow-1);
		main::INFOLOG && $log->is_info && $log->info("found matching format $props{itag}");
		next unless !defined $streamInfo || $index < $selected;

		main::INFOLOG && $log->is_info && $log->info("itag: $props{itag}, props: $props{url}");
						
		my $url = uri_unescape($props{url});
		my $sig;
		my $encrypted = 0;
					
		if (exists $props{s}) {
			$sig = $props{s};
			$encrypted = 1;
		} elsif (exists $props{sig}) {
			$sig = $props{sig};
		} elsif (exists $props{signature}) {
			$sig = $props{signature};
		} else {
			$sig = '';
		}
											
		main::INFOLOG && $log->is_info && $log->info("selected $$allow[$index][1] sig $sig encrypted $encrypted");
							
		$streamInfo = { url => $url, sig => $sig, encrypted => $encrypted, format => $$allow[$index][1] };
		$selected = $index;
	}
		
	return $streamInfo;
}

sub getMPD {
	my ($dashmpd, $allow, $cb) = @_;
	
	# get MPD file
	Slim::Networking::SimpleAsyncHTTP->new(

		sub {
			my $http = shift;
			my $selIndex;
			my ($selRepres, $selAdapt);
			my $mpd = XMLin( $http->content, KeyAttr => [], ForceContent => 1, ForceArray => [ 'AdaptationSet', 'Representation', 'Period' ] );
			my $period = $mpd->{'Period'}[0];
			my $adaptationSet = $period->{'AdaptationSet'}; 
			
			$log->error("Only one period supported") if @{$mpd->{'Period'}} != 1;
						
			#$log->error(Dumper($mpd));
																		
			# find suitable format, first preferred
			foreach my $adaptation (@$adaptationSet) {
				if ($adaptation->{'mimeType'} eq 'audio/mp4') {
																											
					foreach my $representation (@{$adaptation->{'Representation'}}) {
						next unless my ($index) = grep { $$allow[$_][0] == $representation->{'id'} } (0 .. @$allow-1);
						main::INFOLOG && $log->is_info && $log->info("found matching format $representation->{'id'}");
						next unless !defined $selIndex || $index < $selIndex;
												
						$selIndex = $index;
						$selRepres = $representation;
						$selAdapt = $adaptation;
					}	
				}	
			}
			
			main::INFOLOG && $log->is_info && $log->info("selected $selRepres->{'id'}");
			
			my $timeShiftDepth	= $selRepres->{'SegmentList'}->{'timeShiftBufferDepth'} // 
								  $selAdapt->{'SegmentList'}->{'timeShiftBufferDepth'} // 
								  $period->{'SegmentList'}->{'timeShiftBufferDepth'} // 
								  $mpd->{'timeShiftBufferDepth'};
			my ($misc, $hour, $min, $sec) = $timeShiftDepth =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:([+-]?([0-9]*[.])?[0-9]+)S)?/;
			$timeShiftDepth	= ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);
					
			($misc, $hour, $min, $sec) = $mpd->{'minimumUpdatePeriod'} =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:([+-]?([0-9]*[.])?[0-9]+)S)?/;
			my $updatePeriod = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);
			$updatePeriod = min($updatePeriod * 10, $timeShiftDepth / 2) if $updatePeriod && $timeShiftDepth && !$prefs->get('live_edge');
						
			my $duration = $mpd->{'mediaPresentationDuration'};
			($misc, $hour, $min, $sec) = $duration =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:([+-]?([0-9]*[.])?[0-9]+)S)?/;
			$duration = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);
									
			my $scaleDuration	= $selRepres->{'SegmentList'}->{'duration'} // 
								  $selAdapt->{'SegmentList'}->{'duration'} //
								  $period->{'SegmentList'}->{'duration'};
			my $timescale 		= $selRepres->{'SegmentList'}->{'timescale'} // 
								  $selAdapt->{'SegmentList'}->{'timescale'} //
								  $period->{'SegmentList'}->{'timescale'};
				
			$duration = $scaleDuration / $timescale if $scaleDuration;		
			
			main::INFOLOG && $log->is_info && $log->info("MPD update period $updatePeriod, timeshift $timeShiftDepth, duration $duration");
												
			my $props = {
					format 			=> $$allow[$selIndex][1],
					updatePeriod	=> $updatePeriod,
					baseURL 		=> $selRepres->{'BaseURL'}->{'content'} // 
									   $selAdapt->{'BaseURL'}->{'content'} // 
									   $period->{'BaseURL'}->{'content'} // 
									   $mpd->{'BaseURL'}->{'content'},
					segmentTimeline => $selRepres->{'SegmentList'}->{'SegmentTimeline'}->{'S'} // 
									   $selAdapt->{'SegmentList'}->{'SegmentTimeline'}->{'S'} //
									   $period->{'SegmentList'}->{'SegmentTimeline'}->{'S'},
					segmentURL		=> $selRepres->{'SegmentList'}->{'SegmentURL'} // 
									   $selAdapt->{'SegmentList'}->{'SegmentURL'} // 
									   $period->{'SegmentList'}->{'SegmentURL'},
					initializeURL	=> $selRepres->{'SegmentList'}->{'Initialization'}->{'sourceURL'} // 
									   $selAdapt->{'SegmentList'}->{'Initialization'}->{'sourceURL'} // 
									   $period->{'SegmentList'}->{'Initialization'}->{'sourceURL'},
					startNumber		=> $selRepres->{'SegmentList'}->{'startNumber'} // 
									   $selAdapt->{'SegmentList'}->{'startNumber'} // 
									   $period->{'SegmentList'}->{'startNumber'},
					samplingRate	=> $selRepres->{'audioSamplingRate'} // 
									   $selAdapt->{'audioSamplingRate'},
					channels		=> $selRepres->{'AudioChannelConfiguration'}->{'value'} // 
									   $selAdapt->{'AudioChannelConfiguration'}->{'value'},
					bandwidth		=> $selRepres->{'bandwidth'},
					duration		=> $duration,
					timescale		=> $timescale || 1,
					timeShiftDepth	=> $timeShiftDepth,
					mpd				=> { url => $dashmpd, type => $mpd->{'type'}, 
										 adaptId => $selAdapt->{'id'}, represId => $selRepres->{'id'}, 
									},	 
				};	
				
			# calculate live edge
			if ($updatePeriod && $prefs->get('live_edge') && $props->{'segmentTimeline'}) {
				my $index = scalar @{$props->{'segmentTimeline'}} - 1;
				my $delay = $prefs->get('live_delay');
	
				while ($delay > 0 && $index > 0) {
					$delay -= ${$props->{'segmentTimeline'}}[$index]->{'d'} / $props->{'timescale'};
					$index--;
				}	
				
				$props->{'liveOffset'} = $index;
				main::INFOLOG && $log->is_info && $log->info("live edge $index/", scalar @{$props->{'segmentTimeline'}});
			}	
								
			$cb->($props);
		},
		
		sub {
			$log->error("cannot get MPD file $dashmpd");
			$cb->();
		},		
					
	)->get($dashmpd);
}

sub updateMPD {
	my $self = shift;
	my $v = $self->vars;
	my $props = ${*$self}{'props'};
	my $song = ${*$self}{'song'};
	
	return unless ${*$self}{'active'} && $props && $props->{'updatePeriod'} && $song->isActive;
		
	# get MPD file
	Slim::Networking::SimpleAsyncHTTP->new(

		sub {
			my $http = shift;
			my $mpd = XMLin( $http->content, KeyAttr => [], ForceContent => 1, ForceArray => [ 'AdaptationSet', 'Representation', 'Period' ] );
			my $period = $mpd->{'Period'}[0];
			
			$log->error("Only one period supported") if @{$mpd->{'Period'}} != 1;
			
			my ($selAdapt) = grep { $_->{'id'} == $props->{'mpd'}->{'adaptId'} } @{$period->{'AdaptationSet'}}; 
			my ($selRepres) = grep { $_->{'id'} == $props->{'mpd'}->{'represId'} } @{$selAdapt->{'Representation'}}; 
			
			#$log->error("UPDATEMPD ", Dumper($selRepres));
						
			my $startNumber = $selRepres->{'SegmentList'}->{'startNumber'} // 
							  $selAdapt->{'SegmentList'}->{'startNumber'} // 
						   	  $period->{'SegmentList'}->{'startNumber'};
							  
			my ($misc, $hour, $min, $sec) = $mpd->{'minimumUpdatePeriod'} =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:([+-]?([0-9]*[.])?[0-9]+)S)?/;
			my $updatePeriod = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);
			$updatePeriod = min($updatePeriod * 10, $props->{'timeShiftDepth'} / 2) if $updatePeriod && $props->{'timeShiftDepth'} && !$props->{'liveOffset'};
			
			main::INFOLOG && $log->is_info && $log->info("offset $v->{'offset'} adjustement ", $startNumber - $props->{'startNumber'}, ", update period $updatePeriod");			
			$v->{'offset'} -= $startNumber - $props->{'startNumber'};	
						
			$props->{'startNumber'} = $startNumber;
			$props->{'updatePeriod'} = $updatePeriod;
			$props->{'segmentTimeline'} = $selRepres->{'SegmentList'}->{'SegmentTimeline'}->{'S'} // 
										  $selAdapt->{'SegmentList'}->{'SegmentTimeline'}->{'S'} //
										  $period->{'SegmentList'}->{'SegmentTimeline'}->{'S'};
			$props->{'segmentURL'} = $selRepres->{'SegmentList'}->{'SegmentURL'} // 
									 $selAdapt->{'SegmentList'}->{'SegmentURL'} // 
									 $period->{'SegmentList'}->{'SegmentURL'};
			
			$v->{'streaming'} = 1 if $v->{'offset'} != @{$props->{'segmentURL'}};
			Slim::Utils::Timers::setTimer($self, time() + $updatePeriod, \&updateMPD);

			# UI displayed position is startOffset + elapsed so that it appeared fixed
			$song->startOffset( $props->{'startOffset'} - $song->master->songElapsedSeconds);
		},
		
		sub {
			$log->error("cannot update MPD file $props->{'mpd'}->{'url'}");
		},		
					
	)->get($props->{'mpd'}->{'url'});
	
}

sub getSignature {
	my ($content, $sig, $encrypted, $cb) = @_;
		
	# signature is not encrypted	
	if ( !$encrypted ) {
		$cb->($sig);
		return;
	}
	
	# get the player's url
	my ($player_url) = ($content =~ /"assets":.+?"js":\s*("[^"]+")/);
	
	if ( !$player_url ) { 
		$log->error("no player url to unobfuscate signature");
		$cb->();
		return;
	}	
	
	$player_url = JSON::XS->new->allow_nonref(1)->decode($player_url);
	if ( $player_url  =~ m,^//, ) {
		$player_url = "https:" . $player_url;
	} elsif ($player_url =~ m,^/,) {
		$player_url = "https://www.youtube.com" . $player_url;
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("player_url: $player_url");
	
	# is signature cached 
	if ( Plugins::YouTube::Signature::has_player($player_url) ) {
		$cb->(Plugins::YouTube::Signature::unobfuscate_signature($player_url, $sig));
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug("Fetching new player $player_url");
		Slim::Networking::SimpleAsyncHTTP->new(
	
			sub {
				my $http = shift;
				my $jscode = $http->content;

				eval {
					Plugins::YouTube::Signature::cache_player($player_url, $jscode);
					main::DEBUGLOG && $log->is_debug && $log->debug("Saved new player $player_url");
					};
						
				if ($@) {
					$log->error("cannot load player code: $@");
					$cb->();
				} else {
					$cb->(Plugins::YouTube::Signature::unobfuscate_signature($player_url, $sig));
				}	
			},
						
			sub {
				$log->error->("Cannot fetch player");
				$cb->();
			},
	
		)->get($player_url);
	}	
}	

sub getMetadataFor {
	my ($class, $client, $url) = @_;
	my $icon = $class->getIcon();
	
	main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url");
				
	my $id = $class->getId($url) || return {};
		
	if (my $meta = $cache->get("yt:meta-$id")) {
		my $song = $client->playingSong();
		
		if ($song && $song->currentTrack()->url eq $url) {
			$song->track->secs( $meta->{duration} ) if $song && $song->currentTrack()->url eq $url;
			if (defined $meta->{_thumbnails}) {
				$meta->{cover} = $meta->{icon} = Plugins::YouTube::Plugin::_getImage($meta->{_thumbnails}, 1);				
				delete $meta->{_thumbnails};
				$cache->set("yt:meta-$id", $meta);
				main::INFOLOG && $log->is_info && $log->info("updating thumbnail cache with hires $meta->{cover}");
			}
		}	
											
		Plugins::YouTube::Plugin->updateRecentlyPlayed({
			url  => $url, 
			name => $meta->{_fulltitle} || $meta->{title}, 
			icon => $meta->{icon},
		});

		main::DEBUGLOG && $log->is_debug && $log->debug("cache hit: $id");
		
		return $meta;
	}
	
	if ($client->master->pluginData('fetchingYTMeta')) {
		main::DEBUGLOG && $log->is_debug && $log->debug("already fetching metadata: $id");
		return {	
			type	=> 'YouTube',
			title	=> $url,
			icon	=> $icon,
			cover	=> $icon,
		};	
	}
	
	# Go fetch metadata for all tracks on the playlist without metadata
	my $pageCall;

	$pageCall = sub {
		my ($status) = @_;
		my @need;
		
		for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
			my $trackURL = blessed($track) ? $track->url : $track;
			if ( $trackURL =~ m{youtube:/*(.+)} ) {
				my $trackId = $class->getId($trackURL);
				if ( $trackId && !$cache->get("yt:meta-$trackId") ) {
					push @need, $trackId;
				}
				elsif (!$trackId) {
					$log->warn("No id found: $trackURL");
				}
			
				# we can't fetch more than 50 at a time
				last if (scalar @need >= 50);
			}
		}
						
		if (scalar @need && !defined $status) {
			my $list = join( ',', @need );
			main::INFOLOG && $log->is_info && $log->info( "Need to fetch metadata for: $list");
			_getBulkMetadata($client, $pageCall, $list);
		} else {
			$client->master->pluginData(fetchingYTMeta => 0);
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );	
		} 
	};

	$client->master->pluginData(fetchingYTMeta => 1);
	
	# get the one item if playlist empty
	if ( Slim::Player::Playlist::count($client) ) { $pageCall->() }
	else { _getBulkMetadata($client, undef, $id) }
		
	return {	
			type	=> 'YouTube',
			title	=> $url,
			icon	=> $icon,
			cover	=> $icon,
	};
}	
	
sub _getBulkMetadata {
	my ($client, $cb, $ids) = @_;
	
	Plugins::YouTube::API->getVideoDetails( sub {
		my $result = shift;
		
		if ( !$result || $result->{error} || !$result->{pageInfo}->{totalResults} || !scalar @{$result->{items}} ) {
			$log->error($result->{error} || 'Failed to grab track information');
			$cb->(0) if defined $cb;
			return;
		}
		
		foreach my $item (@{$result->{items}}) {
			my $snippet = $item->{snippet};
			my $title   = $snippet->{'title'};
			my $cover   = my $icon = Plugins::YouTube::Plugin::_getImage($snippet->{thumbnails});
			my $artist  = "";
			my $fulltitle;
	
			if ($title =~ /(.*) - (.*)/) {
				$fulltitle = $title;
				$artist = $1;
				$title  = $2;
			}
	
			my $duration = $item->{contentDetails}->{duration};
			main::DEBUGLOG && $log->is_debug && $log->debug("Duration: $duration");
			my ($misc, $hour, $min, $sec) = $duration =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/;
			$duration = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);
									
			my $meta = {
				title    =>	$title || '',
				artist   => $artist,
				duration => $duration || 0,
				icon     => $icon,
				cover    => $cover || $icon,
				type     => 'YouTube',
				_fulltitle => $fulltitle,
				_thumbnails => $snippet->{thumbnails},
			};
				
			$cache->set("yt:meta-" . $item->{id}, $meta, 86400);
		}				
			
		$cb->() if defined $cb;
		
	}, $ids);
}


sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::YouTube::Plugin->_pluginDataFor('icon');
}



1;
