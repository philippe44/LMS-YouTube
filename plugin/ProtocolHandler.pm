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
use URI::QueryParam;
use Scalar::Util qw(blessed);
use JSON::XS;
use Data::Dumper;
use File::Spec::Functions;
use FindBin qw($Bin);
use XML::Simple;
use POSIX qw(strftime);

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
use constant PAGE_URL_REGEXP => qr{^https?://(?:(?:www|m|music)\.youtube\.com/(?:watch\?|playlist\?|channel/)|youtu\.be/)}i;

my $log   = logger('plugin.youtube');
my $prefs = preferences('plugin.youtube');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('youtube', __PACKAGE__);
Slim::Player::ProtocolHandlers->registerURLHandler(PAGE_URL_REGEXP, __PACKAGE__)
    if Slim::Player::ProtocolHandlers->can('registerURLHandler');

sub flushCache { $cache->cleanup(); }

=comment
There is a voluntaty 'confusion' between codecs and streaming formats
(regular http or dash). As we only support ogg/opus with webm and aac
withdash, this is not a problem at this point, although not very elegant.
This only works because it seems that YT, when using webm and dash (171)
does not build a mpd file but instead uses regular webm. It might be due
to http://wiki.webmproject.org/adaptive-streaming/webm-dash-specification
but I'm not sure at that point. Anyway, the dash webm format used in codec
171, 251, 250 and 249, probably because there is a single stream, does not
need a different handling than normal webm
=cut

my $setProperties  = { 	'ogg' => \&Plugins::YouTube::WebM::setProperties,
						'ops' => \&Plugins::YouTube::WebM::setProperties,
						'aac' => \&Plugins::YouTube::M4a::setProperties
				};
my $getAudio 	   = { 	'ogg' => \&Plugins::YouTube::WebM::getAudio,
						'ops' => \&Plugins::YouTube::WebM::getAudio,
						'aac' => \&Plugins::YouTube::M4a::getAudio
				};
my $getStartOffset = { 	'ogg' => \&Plugins::YouTube::WebM::getStartOffset,
						'ops' => \&Plugins::YouTube::WebM::getStartOffset,
						'aac' => \&Plugins::YouTube::M4a::getStartOffset
				};

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

	# erase last position from cache
	$cache->remove("yt:lastpos-" . $class->getId($args->{'url'}));

	# set offset depending on format
	$offset = $props->{'liveOffset'} if $props->{'liveOffset'};
	$offset = $props->{offset}->{clusters} if $props->{offset}->{clusters};

	$args->{'url'} = $song->pluginData('baseURL');

	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'} || $song->pluginData('lastpos');
	$song->pluginData('lastpos', 0);

	if ($startTime) {
		$song->can('startOffset') ? $song->startOffset($startTime) : ($song->{startOffset} = $startTime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $startTime);
		$offset = undef;
	}

	main::INFOLOG && $log->is_info && $log->info("url: $args->{url} offset: ", $startTime || 0);

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
			'session' 	  => Slim::Networking::Async::HTTP->new,
			'baseURL'	  => $args->{'url'},
			'retry'       => 5,
		};
	}

	# set starting offset (bytes or index) if not defined yet
	$getStartOffset->{$props->{'format'}}($args->{url}, $startTime, $props, sub {
			${*$self}{'vars'}->{offset} = shift;
			$log->info("starting from offset ", ${*$self}{'vars'}->{offset});
		}
	) if !defined $offset;

	# set timer for updating the MPD if needed (dash)
	${*$self}{'active'}  = 1;
	Slim::Utils::Timers::setTimer($self, time() + $props->{'updatePeriod'}, \&updateMPD) if $props->{'updatePeriod'};

	# for live stream, always set duration to timeshift depth
	if ($props->{'timeShiftDepth'}) {
		# only set offset when missing startTime or not starting from live edge
		$song->startOffset($props->{'timeShiftDepth'} - $prefs->get('live_delay')) unless $startTime || !$props->{'liveOffset'};
		$song->duration($props->{'timeShiftDepth'});
		$song->pluginData('liveStream', 1);
		$props->{'startOffset'} = $song->startOffset;
	} else {
		$song->pluginData('liveStream', 0);
	}

	return $self;
}

sub close {
	my $self = shift;

	${*$self}{'active'} = 0;
	${*$self}{'vars'}->{'session'}->disconnect;

	if (${*$self}{'props'}->{'updatePeriod'}) {
		main::INFOLOG && $log->is_info && $log->info("killing MPD update timer");
		Slim::Utils::Timers::killTimers($self, \&updateMPD);
	}

	main::INFOLOG && $log->is_info && $log->info("end of streaming for ", ${*$self}{'song'}->track->url);

	$self->SUPER::close(@_);
}

sub onStop {
    my ($class, $song) = @_;
	my $elapsed = $song->master->controller->playingSongElapsed;
	my $id = Plugins::YouTube::ProtocolHandler->getId($song->track->url);

	# return if $song->pluginData('liveStream');

	if ($elapsed < $song->duration - 15) {
		$cache->set("yt:lastpos-$id", int ($elapsed), '30days');
		$log->info("Last position for $id is $elapsed");
	} else {
		$cache->remove("yt:lastpos-$id");
	}
}

sub onStream {
	my ($class, $client, $song) = @_;
	my $url = $song->track->url;

	$url =~ s/&lastpos=([\d]+)//;

	my $id = Plugins::YouTube::ProtocolHandler->getId($url);
	my $meta = $cache->get("yt:meta-$id") || {};

	Plugins::YouTube::Plugin->updateRecentlyPlayed( {
		url  => $url,
		name => $meta->{_fulltitle} || $meta->{title} || $song->track->title,
		icon => $meta->{icon} || $song->icon,
	} );
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

sub songBytes { }

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
	my $props = ${*$self}{'props'};

	# means waiting for offset to be set
	if ( !defined $v->{offset} ) {
		$! = EINTR;
		return undef;
	}

	# need more data
	if ( length $v->{'outBuf'} < MIN_OUT && !$v->{'fetching'} && $v->{'streaming'} ) {
		my $url = $v->{'baseURL'};
		my $headers = [ 'Connection', 'keep-alive' ];
		my $suffix;

		if ( $props->{'segmentURL'} ) {
			$suffix = ${$props->{'segmentURL'}}[$v->{'offset'}]->{'media'};
			$url .= $suffix;
		} else {
			push @$headers, 'Range', "bytes=$v->{offset}-" . ($v->{offset} + DATA_CHUNK - 1);
		}

		my $request = HTTP::Request->new( GET => $url, $headers);
		$request->protocol( 'HTTP/1.1' );

		$v->{'fetching'} = 1;

		$v->{'session'}->send_request( {
			request => $request,

			onRedirect => sub {
				my $redirect = shift->uri;

				if ( $props->{'segmentURL'} ) {
					my $match = (reverse ($suffix) ^ reverse ($redirect)) =~ /^(\x00*)/;
					$v->{'baseURL'} = substr $redirect, 0, -$+[1] if $match;
				} else {
					$v->{'baseURL'} = $redirect;
				}

				main::INFOLOG && $log->is_info && $log->info("being redirected from $url to $redirect using new base $v->{baseURL}");
			},

			onBody => sub {
				my $response = shift->response;

				$v->{'inBuf'} .= $response->content;
				$v->{'fetching'} = 0;
				$v->{'retry'} = 5;

				if ( $props->{'segmentURL'} ) {
					$v->{'offset'}++;
					$v->{'streaming'} = 0 if $v->{'offset'} == @{$props->{'segmentURL'}};
					main::DEBUGLOG && $log->is_debug && $log->debug("got chunk $v->{'offset'} length: ", length $response->content, " for $url");
				} else {
					($v->{length}) = $response->header('content-range') =~ /\/(\d+)$/ unless $v->{length};
					my $len = length $response->content;
					$v->{offset} += $len;
					$v->{'streaming'} = 0 if ($len < DATA_CHUNK && !$v->{length}) || ($v->{offset} == $v->{length});
					main::DEBUGLOG && $log->is_debug && $log->debug("got chunk length: $len from ", $v->{offset} - $len, " for $url");
				}
			},

			onError => sub {
				$log->warn("error $v->{retry} fetching $url") unless $v->{'baseURL'} ne ${*$self}{'url'} && $v->{'retry'};
				$v->{'retry'}--;
				$v->{'fetching'} = 0 if $v->{retry} > 0;
				$v->{'baseURL'} = ${*$self}{'url'};
			},
		} );
	}

	# process all available data
	$getAudio->{$props->{'format'}}($v, $props) if length $v->{'inBuf'};

	if ( my $bytes = min(length $v->{'outBuf'}, $maxBytes) ) {
		$_[1] = substr($v->{'outBuf'}, 0, $bytes, '');

		return $bytes;
	} elsif ( ($v->{'streaming'} || $props->{'updatePeriod'}) && $v->{'retry'} > 0 ) {
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

	# also youtube://http://www.youtube.com/watch?v=tU0_rKD8qjw

	if ($url =~ /^(?:youtube:\/\/)?https?:\/\/(?:www|m)\.youtube\.com\/watch\?v=([^&]*)/ ||
		$url =~ /^youtube:\/\/(?:www|m)\.youtube\.com\/v\/([^&]*)/ ||
		$url =~ /^youtube:\/\/([^&]*)/ ||
		$url =~ m{^https?://youtu\.be/([a-zA-Z0-9_\-]+)}i ||
		$url =~ /([a-zA-Z0-9_\-]+)/ )
		{

		return $1;
	}

	return undef;
}

# fetch the YouTube player url and extract a playable stream
sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $masterUrl = $song->track()->url;

	$song->pluginData(lastpos => ($masterUrl =~ /&lastpos=([\d]+)/)[0] || 0);
	$masterUrl =~ s/&.*//;

	my $id = $class->getId($masterUrl);

	my @allow = ( [43, 'ogg', 0], [44, 'ogg', 0], [45, 'ogg', 0], [46, 'ogg', 0] );
	my @allowDASH = ();

	main::INFOLOG && $log->is_info && $log->info("next track id: $id url: $url master: $masterUrl");

	push @allowDASH, ( [251, 'ops', 160_000], [250, 'ops', 70_000], [249, 'ops', 50_000], [171, 'ogg', 128_000] ) if $prefs->get('ogg');
	push @allowDASH, ( [141, 'aac', 256_000], [140, 'aac', 128_000], [139, 'aac', 48_000] ) if $prefs->get('aac');
	@allowDASH = sort {@$a[2] < @$b[2]} @allowDASH;

	# need to set consent cookie if pending
	my $cookieJar = Slim::Networking::Async::HTTP::cookie_jar();
   	 my $socs = $cookieJar->get_cookies('www.youtube.com', 'SOCS');
    	if (!$socs || $socs =~ /^CAA/) {
		$cookieJar->set_cookie(0, 'SOCS', 'CAI', '/', '.youtube.com', undef, undef, 1, 3600*24*365);
		$log->info("Acceping CONSENT cookie");
    	}

	# fetch new url(s)

    	my $http_url = 'https://www.youtube.com/youtubei/v1/player?key='.$prefs->get('APIkey').'&prettyPrint=false';
    	my $http_data = {context => {client => {clientName => "IOS", clientVersion => "19.09.3", deviceModel => "iPhone14,3", userAgent => "com.google.ios.youtube/19.09.3 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)", hl => "en", timeZone => "UTC", utcOffsetMinutes => 0}}, videoId => $id, playbackContext => {contentPlaybackContext => {html5Preference => "HTML5_PREF_WANTS"}}, contentCheckOk => "true", racyCheckOk => "true"};

    	Slim::Networking::SimpleAsyncHTTP->new(
     
        	sub {
            		my $response = shift;
            		my $http_result = $response->content;

            		main::DEBUGLOG && $log->is_debug && $log->debug($http_result);

            		my $streams = eval { decode_json($http_result) };
            		my $streamInfo = getStreamJSON($streams->{'streamingData'}->{'adaptiveFormats'}, \@allowDASH);

            		my $props = { format => $streamInfo->{'format'}, bitrate => $streamInfo->{'bitrate'} };

            		$song->pluginData(props => $props);
            		$song->pluginData(baseURL  => "$streamInfo->{'url'}");
            		$setProperties->{$props->{'format'}}($song, $props, $successCb, $errorCb)
        	},

        	sub {
            		warn Data::Dump::dump(@_);
            		$log->error("could not load stream, $_[1]");
        	},

        	{
            		timeout => 15,
		}
  	)->post($http_url,encode_json($http_data));
}

sub getStreamJSON {
	my ($streams, $allow) = @_;
	my $streamInfo;
	my $selected;

	# transcode unicode escaped \uNNNN characters (mainly 0026 = &)
	$streams =~ s/\\u(.{4})/chr(hex($1))/eg;

	for my $stream (@{$streams}) {
		my $index;

		main::INFOLOG && $log->is_info && $log->info("found itag: $stream->{itag}");
		main::DEBUGLOG && $log->is_debug && $log->debug($stream);

		# check streams in preferred id order
        next unless ($index) = grep { $$allow[$_][0] == $stream->{itag} } (0 .. @$allow-1);
		main::INFOLOG && $log->is_info && $log->info("matching format $stream->{itag}");
		next unless !defined $streamInfo || $index < $selected;

		my $url;
		my $sig = '';
		my $encrypted = 0;
		my %props;
		my $cipher = $stream->{cipher} || $stream->{signatureCipher};

		if ($cipher) {
			%props = map { $_ =~ /=(.+)/ ? split(/=/, $_) : () } split(/&/, $cipher);

			$url = uri_unescape($props{url});

			if (exists $props{s}) {
				$sig = $props{s};
				$encrypted = 1;
			} elsif (exists $props{sig}) {
				$sig = $props{sig};
			} elsif (exists $props{signature}) {
				$sig = $props{signature};
			}
		} else {
			$url = uri_unescape($stream->{url});
		}

		$sig = uri_unescape($sig);

		main::INFOLOG && $log->is_info && $log->info("candidate itag: $stream->{itag}, url/cipher: ", $cipher || $stream->{url});
		main::INFOLOG && $log->is_info && $log->info("candidate $$allow[$index][1] sig $sig encrypted $encrypted");

		$streamInfo = { url => $url, sp => $props{sp} || 'signature', sig => $sig, encrypted => $encrypted, format => $$allow[$index][1], bitrate => $$allow[$index][2] };
		$selected = $index;
	}

	return $streamInfo;
}

sub getMPD {
	my ($dashmpd, $allow, $cb) = @_;

	# transcode unicode espaced characters
	$dashmpd =~ s/\\u(.{4})/chr(hex($1))/eg;

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

			# might not have found anything
			return $cb->() unless $selRepres;
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
					bitrate			=> $selRepres->{'bandwidth'},
					duration		=> $duration,
					timescale		=> $timescale || 1,
					timeShiftDepth	=> $timeShiftDepth,
					mpd				=> { url => $dashmpd, type => $mpd->{'type'},
										 adaptId => $selAdapt->{'id'}, represId => $selRepres->{'id'},
									},
			};

			# sanity check and trace
			if (ref $props->{'segmentURL'} ne 'ARRAY') {
				$log->error("SegmentURL is not an ARRAY ", Dumper($mpd, $props));
				return $cb->();
			}

			# calculate live edge
			if ($updatePeriod && $prefs->get('live_edge') && $props->{'segmentTimeline'}) {
				my $index = scalar @{$props->{'segmentTimeline'}} - 1;
				my $delay = $prefs->get('live_delay');
				my $edgeYield = 0;

				while ($delay > $edgeYield && $index > 0) {
					$edgeYield += ${$props->{'segmentTimeline'}}[$index]->{'d'} / $props->{'timescale'};
					$index--;
				}

				$props->{'edgeYield'} = $edgeYield;
				$props->{'liveOffset'} = $index;
				main::INFOLOG && $log->is_info && $log->info("live edge $index/", scalar @{$props->{'segmentTimeline'}}, ", edge yield $props->{'edgeYield'}");
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

	# try many ways to detect inactive song - seems that the timer is "difficult" to stop
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

			#$log->error("UPDATEMPD ", Dumper($mpd));

			my $startNumber = $selRepres->{'SegmentList'}->{'startNumber'} //
							  $selAdapt->{'SegmentList'}->{'startNumber'} //
						   	  $period->{'SegmentList'}->{'startNumber'};

			my ($misc, $hour, $min, $sec) = $mpd->{'minimumUpdatePeriod'} =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:([+-]?([0-9]*[.])?[0-9]+)S)?/;
			my $updatePeriod = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);

			if ($updatePeriod && $props->{'timeShiftDepth'}) {
				$updatePeriod = max($updatePeriod, $props->{'edgeYield'} / 2);
				$updatePeriod = min($updatePeriod, $props->{'timeShiftDepth'} / 2);
			}

			main::INFOLOG && $log->is_info && $log->info("offset $v->{'offset'} adjustement ", $startNumber - $props->{'startNumber'}, ", update period $updatePeriod");
			$v->{'offset'} -= $startNumber - $props->{'startNumber'};
			$v->{'offset'} = 0 if $v->{'offset'} < 0;

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

sub getMetadataFor {
	my ($class, $client, $full_url) = @_;
	my $icon = $class->getIcon();

	my ($url) = $full_url =~ /([^&]*)/;
	my $id = $class->getId($url) || return {};

	main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url");

	if (my $meta = $cache->get("yt:meta-$id")) {
		my $song = $client->playingSong();

		if ($song && $song->currentTrack()->url eq $full_url) {
			$song->track->secs( $meta->{duration} );
			if (defined $meta->{_thumbnails}) {
				$meta->{cover} = $meta->{icon} = Plugins::YouTube::Plugin::_getImage($meta->{_thumbnails}, 1);
				delete $meta->{_thumbnails};
				$cache->set("yt:meta-$id", $meta);
				main::INFOLOG && $log->is_info && $log->info("updating thumbnail cache with hires $meta->{cover}");
			}
		}

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
		my ($abort) = @_;

		my @need;

		for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
			my $trackURL = blessed($track) ? $track->url : $track;

			if ( $trackURL =~ m{youtube:/*(.+)} ) {
				my $trackId = $class->getId($trackURL);

				if ( $trackId && !$cache->get("yt:meta-$trackId") ) {
					push @need, $trackId;
				} elsif (!$trackId) {
					$log->warn("No id found: $trackURL");
				}

				# we can't fetch more than 50 at a time
				last if (scalar @need >= 50);
			}
		}

		if (scalar @need && !$abort) {
			my $list = join( ',', @need );
			main::INFOLOG && $log->is_info && $log->info( "Need to fetch metadata for: $list");
			_getBulkMetadata($client, $pageCall, $list);
		} else {
			$client->master->pluginData(fetchingYTMeta => 0);
			unless ($abort) {
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
			}
		}
	};

	$client->master->pluginData(fetchingYTMeta => 1);

	# get the one item if playlist empty
	if ( Slim::Player::Playlist::count($client) ) {
		$pageCall->();
	} else {
		_getBulkMetadata($client, undef, $id);
	}

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
			$cb->(1) if defined $cb;
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

sub explodePlaylist {
	my ( $class, $client, $uri, $cb ) = @_;

	return $cb->([$uri]) unless $uri =~ PAGE_URL_REGEXP;

	$uri = URI->new($uri);

	my $handler;
	my $search;
	if ( $uri->host eq 'youtu.be' ) {
		$handler = \&Plugins::YouTube::Plugin::urlHandler;
		$search = ($uri->path_segments)[1];
	}
	elsif ( $uri->path eq '/watch' ) {
		$handler = \&Plugins::YouTube::Plugin::urlHandler;
		$search = $uri->query_param('v');
	}
	elsif ( $uri->path eq '/playlist' ) {
		$handler = \&Plugins::YouTube::Plugin::playlistIdHandler;
		$search = $uri->query_param('list');
	}
	elsif ( ($uri->path_segments)[1] eq 'channel' ) {
		$handler = \&Plugins::YouTube::Plugin::channelIdHandler;
		$search = ($uri->path_segments)[2];
	}
	$handler->(
		$client,
		sub { $cb->([map {$_->{'play'}} @{$_[0]->{'items'}}]) },
		{'search' => $search},
		{},
	);
}

1;
