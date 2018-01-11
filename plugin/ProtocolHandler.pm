package Plugins::YouTube::ProtocolHandler;
use base qw(IO::Handle);

use strict;

use List::Util qw(min max first);
use HTML::Parser;
use URI::Escape;
use Scalar::Util qw(blessed);
use JSON::XS;
use Data::Dumper;
use File::Spec::Functions;
use FindBin qw($Bin);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::YouTube::Signature;
use Plugins::YouTube::WebM;

use constant MIN_OUT	=> 8192;
use constant DATA_CHUNK => 65536;	
use constant HEADER_CHUNK => 8192;

my $log   = logger('plugin.youtube');
my $prefs = preferences('plugin.youtube');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('youtube', __PACKAGE__);

sub flushCache { $cache->cleanup(); }

sub new {
	my $class = shift;
	my $args  = shift;
	my $song       = $args->{'song'};
	my $webmInfo = $song->pluginData('webmInfo');
	my $offset = $webmInfo->{offset}->{clusters};
	
	return undef if !defined $webmInfo;
	
	$log->debug( Dumper($webmInfo) );
	
	$args->{'url'} = $song->pluginData('stream');
	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'};
  
	if ($startTime) {
		$song->can('startOffset') ? $song->startOffset($startTime) : ($song->{startOffset} = $startTime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $startTime);
		$offset = 0;
	}
	
	$log->info("url: $args->{url}");
	
	my $self = $class->SUPER::new;
	
	if (defined($self)) {
		${*$self}{'client'}  	= $args->{'client'};
		${*$self}{'song'}    	= $args->{'song'};
		${*$self}{'url'}     	= $args->{'url'};
		${*$self}{'webmInfo'}   = $webmInfo;		
		${*$self}{'vars'} = {         		# variables which hold state for this instance:
			'inBuf'       => '',      		# buffer of received data
			'outBuf'      => '',      		# buffer of processed audio
			'id'          => undef,   		# last EBML identifier
			'need'        => Plugins::YouTube::WebM::EBML_NEED,  # minimum size of data to allow processing
			'position'    => 0,      		# number of bytes processed from buffer since 1st call
			'offset'      => $offset,  		# offset for next HTTP request
			'streaming'   => 1,      		# flag for streaming, changes to 0 when all data received
			'fetching'    => 0,		  		# waiting for HTTP data
		};
	}
	
	getStartOffset( $args->{url}, $startTime, $webmInfo, sub { ${*$self}{'vars'}->{offset} = shift } ) if !$offset;
	
	return $self;
}

sub formatOverride { 'ogg' }

sub contentType { 'ogg' }

sub isAudio { 1 }

sub isRemote { 1 }

sub canDirectStream { return 0; }

sub songBytes {}

sub canSeek { 1 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;

	return { timeOffset => $newtime };
}


sub vars {
	return ${*{$_[0]}}{'vars'};
}


sub sysread {
	use bytes;

	my $self  = $_[0];
	# return in $_[1]
	my $maxBytes = $_[2];
	my $v = $self->vars;
	my $url = ${*$self}{'url'};
	my $webmInfo = ${*$self}{'webmInfo'};
	
	# means waiting for offset to be set
	if ( !$v->{offset} ) {
		$! = EINTR;
		return undef;
	}	
	
	# need more data
	if ( length $v->{'outBuf'} < MIN_OUT && !$v->{'fetching'} && $v->{'streaming'} ) {
		my $range = "bytes=$v->{offset}-" . ($v->{offset} + DATA_CHUNK - 1);
		
		$v->{offset} += DATA_CHUNK;
		$v->{'fetching'} = 1;
						
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$v->{'inBuf'} .= $_[0]->content;
				$v->{'fetching'} = 0;
				$v->{'streaming'} = 0 if length($_[0]->content) < DATA_CHUNK;
				$log->debug("got chunk length: ", length $_[0]->content, " from ", $v->{offset} - DATA_CHUNK, " for $url");
			},
			
			sub { 
				$log->warn("error fetching $url");
				$v->{'inBuf'} = '';
				$v->{'fetching'} = 0;
			}, 
			
		)->get($url, 'Range' => $range );
		
	}	

	# process all available data	
	Plugins::YouTube::WebM::getAudio($v, $webmInfo) if length $v->{'inBuf'};
	
	if ( my $bytes = min(length $v->{'outBuf'}, $maxBytes) ) {
		$_[1] = substr($v->{'outBuf'}, 0, $bytes);
		$v->{'outBuf'} = substr($v->{'outBuf'}, $bytes);
		return $bytes;
	} elsif ( $v->{streaming} ) {
		$! = EINTR;
		return undef;
	}
	
	# end of streaming
	$log->info("end streaming: $url");
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
	my $client = $song->master();
	my $masterUrl = $song->track()->url;
	my $id = $class->getId($masterUrl);
	my $url = "http://www.youtube.com/watch?v=$id";

	$log->info("next track id: $id url: $url master: $masterUrl");

	# fetch new url(s)
	Slim::Networking::SimpleAsyncHTTP->new(

		sub {
			my $http = shift;
			my $varsBlock;

			# parse html to find the flash variables block
			my $p = HTML::Parser->new(api_version => 3,
				start_h => [
					sub {
						my $tag = shift;
						my $attr = shift;
						if ($tag eq 'embed' && $attr->{'type'} eq "application/x-shockwave-flash") {
							$varsBlock = $attr->{flashvars};
						}
					},
					"tagname,attr"
				],
			);

			$p->parse($http->content);

			# decode into playable streams
			my %vars;
			my %streams;
			my @streams;

			for my $var (split(/&/, $varsBlock)) {
				my ($k, $v) = $var =~ /(.*)=(.*)/;
				$vars{$k} = $v;
			}

            if (!defined $vars{url_encoded_fmt_stream_map}) {
                ($vars{url_encoded_fmt_stream_map}) = ($http->content =~ /\"url_encoded_fmt_stream_map\":\"(.*?)\"/);

                # Replace known unicode characters
                $vars{url_encoded_fmt_stream_map} =~ s/\\u0026/\&/g;
                $log->debug("url_encoded_fmt_stream_map: $vars{url_encoded_fmt_stream_map}");
            }
						
			$log->debug($vars{url_encoded_fmt_stream_map});
			
			# find the streams
			my $streamInfo;
			
			for my $stream (split(/,/, $vars{url_encoded_fmt_stream_map})) {
				my $id;
				no strict 'subs';
                my %props = map { split(/=/, $_) } split(/&/, $stream);

				# check streams in preferred id order
                next unless $id = first { $_ == $props{itag} } (43, 44, 45, 46);
				next unless !defined $streamInfo || $id < $streamInfo->{'id'};

			    $log->info("itag: $props{itag}, props: $props{url}");
						
				my $url = uri_unescape($props{url});
				my $rawsig;
				my $encryptedsig = 0;
					
				if (exists $props{s}) {
					$rawsig = $props{s};
					$encryptedsig = 1;
				} elsif (exists $props{sig}) {
					$rawsig = $props{sig};
				} else {
					$rawsig = $props{signature};
				}
											
				$log->info("sig $rawsig encrypted $encryptedsig");
					
				$streamInfo = { id => $id, url => $url, rawsig => $rawsig, encryptedsig => $encryptedsig };
			}

			if (defined $streamInfo) {
							
				if ( $streamInfo->{'encryptedsig'} ) {
					getSignature($vars{player_url}, $http->content, $streamInfo->{'rawsig'}, 
							  sub {
								my $sig = shift;
									
								if (defined $sig) {
									$song->pluginData(stream  => $streamInfo->{'url'} . "&signature=" . $sig);
									getTrackInfo( $client, $song, $successCb );
								} else {	
									$errorCb->("signature problem");
								}	
							  } );
				} else {
					$log->info("raw signature $streamInfo->{'rawsig'}");
					$song->pluginData(stream  => $streamInfo->{'url'} . "&signature=" . $streamInfo->{'rawsig'});
					getTrackInfo( $client, $song, $successCb );
				}
		
			} else { 
				$errorCb->("no streams found");
			}
		},
		
		sub {
			$errorCb->($_[1]);
		},
				
	)->get($url);
}


sub getSignature {
	my ($player_url, $content, $rawsig, $cb) = @_;
							
	if ( !defined $player_url ) {
		($player_url) = ($content =~ /"assets":.+?"js":\s*("[^"]+")/);
						
		if ( $player_url ) { 
			$player_url = JSON::XS->new->allow_nonref(1)->decode($player_url);
			if ( $player_url  =~ m,^//, ) {
				$player_url = "https:" . $player_url;
			} elsif ($player_url =~ m,^/,) {
				$player_url = "https://www.youtube.com" . $player_url;
			}
		}
	}
					
	$log->debug("player_url: $player_url");
		
	if ( !$player_url ) {
		$log->error("no player url to unobfuscate signature");
		$cb->(undef);
		return;
	}
		
	if ( Plugins::YouTube::Signature::has_player($player_url) ) {
		my $sig = Plugins::YouTube::Signature::unobfuscate_signature( $player_url, $rawsig );
		$log->debug("cached player $ player_url, unobfuscated signature (cached) $sig");
		$cb->($sig, $player_url);
	} else {
		$log->debug("Fetching new player $player_url");
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $jscode = $http->content;

				eval {
					Plugins::YouTube::Signature::cache_player($player_url, $jscode);
					$log->debug("Saved new player $player_url");
					};
						
				if ($@) {
					$log->error("cannot load player code: $@");
					$cb->(undef);
					return;
				}	
					
				my $sig = Plugins::YouTube::Signature::unobfuscate_signature( $player_url, $rawsig );
				$log->debug("cached player $ player_url, unobfuscated signature (cached) $sig");
				$cb->($sig, $player_url);
			},
						
			sub {
				$cb->errorCb->("Cannot fetch player " . $_[1]);
				$cb->(undef);
			},
					
		)->get($player_url);
	}	
}	


sub getTrackInfo {
	my ($client, $song, $cb) = @_;
	my $process;
	my $info = {};	
	my $var = {	'inBuf'       => '',
				'id'          => undef,   
				'need'        => Plugins::YouTube::WebM::EBML_NEED,  
				'offset'      => 0,       
		};
	
	$process = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
		
			sub {
				my $content = shift->content;
								
				$var->{'inBuf'} .= $content;
				my $res = Plugins::YouTube::WebM::getHeaders($var, $info);
				
				if ( $res eq Plugins::YouTube::WebM::WEBM_MORE ) {
					return $cb->() if length($content) < HEADER_CHUNK; 
					
					$log->debug("paging: $var->{offset}");
					$var->{offset} += length $content;
					$process->();
				} elsif ( $res eq Plugins::YouTube::WebM::WEBM_DONE ) {	
					$song->track->secs( $info->{'duration'} / 1000 ) if $info->{'duration'};
					$song->track->bitrate( $info->{'track'}->{'bitrate'} );
					$song->track->samplerate( $info->{'track'}->{'samplerate'} );
					$song->track->samplesize( $info->{'track'}->{'samplesize'} );
					$song->track->channels( $info->{'track'}->{'channels'} );
				
					$log->info( "samplerate: $info->{'track'}->{'samplerate'}, bitrate: $info->{'track'}->{'bitrate'}" );
					$song->pluginData('webmInfo' => $info);
													
					$client->currentPlaylistUpdateTime( Time::HiRes::time() );
					Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );	
				
					$cb->();
				} elsif ( $res eq Plugins::YouTube::WebM::WEBM_ERROR ) {
					$log->error( "could not get webm headers" );
					$cb->();
				}		
			},
		
			sub {
				$log->warn("could not get codec info");
				$cb->();
			}
		)->get( $song->pluginData('stream'), 'Range' => "bytes=$var->{'offset'}-" . ($var->{'offset'} + HEADER_CHUNK - 1) );
	 };	
	
	$process->();
}


sub getStartOffset {
	my ($url, $startTime, $info, $cb) = @_;
	my $process;
	my $var = {	'inBuf'       => '',
				'id'          => undef,   
				'need'        => Plugins::YouTube::WebM::EBML_NEED,  
				'offset'      => $info->{offset}->{cues},       
		};
	
	$process = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
		
			sub {
				my $content = shift->content;
								
				$var->{'inBuf'} .= $content;
				my $res = Plugins::YouTube::WebM::getCues($var);
				
				if ( $res eq Plugins::YouTube::WebM::WEBM_MORE ) {
					return $cb->( $info->{offset}->{clusters} ) if length($content) < HEADER_CHUNK; 
					
					$log->debug("paging: $var->{offset}");
					$var->{offset} += length $content;
					$process->();
				} elsif ( $res eq Plugins::YouTube::WebM::WEBM_DONE ) {	
					my $offset = Plugins::YouTube::WebM::getCueOffset($var->{outBuf}, $startTime*($info->{timecode_scale}/1000000)*1000) + $info->{segment_offset};
					$cb->($offset);
				} elsif ( $res eq Plugins::YouTube::WebM::WEBM_ERROR ) {
					$log->warn( "could not find start offset" );
					$cb->( $info->{offset}->{clusters} );
				}		
			},
		
			sub {
				$log->warn( "could not find start offset" );
				$cb->( $info->{offset}->{clusters} );
			}
		)->get( $url, 'Range' => "bytes=$var->{'offset'}-" . ($var->{'offset'} + HEADER_CHUNK - 1) );
	 };	
	
	$process->();
}


sub getMetadataFor {
	my ($class, $client, $url) = @_;
	my $icon = $class->getIcon();
	
	main::DEBUGLOG && $log->debug("getmetadata: $url");
				
	my $id = $class->getId($url) || return {};
		
	if (my $meta = $cache->get("yt:meta-$id")) {
	
		my $song = $client->playingSong();
		$song->track->secs( $meta->{duration} ) if $song && $song->currentTrack()->url eq $url;
											
		Plugins::YouTube::Plugin->updateRecentlyPlayed({
			url  => $url, 
			name => $meta->{_fulltitle} || $meta->{title}, 
			icon => $meta->{icon},
		});

		main::DEBUGLOG && $log->debug("cache hit: $id");
		
		return $meta;
	}
	
	if ($client->master->pluginData('fetchingYTMeta')) {
		$log->debug("already fetching metadata: $id");
		return {	
			type	=> 'YouTube',
			title	=> $url,
			icon	=> $icon,
			cover	=> $icon,
		};	
	}
	
	# Go fetch metadata for all tracks on the playlist without metadata
	my $pagingCb;

	$pagingCb = sub {
		my ($status) = @_;
		my @need;
		
		for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
			my $trackURL = blessed($track) ? $track->url : $track;
			if ( $trackURL =~ m{youtube:/*(.+)} ) {
				my $trackId = $class->getId($trackURL);
				if ( $trackId && !$cache->get("yt:meta-$trackId") && $trackId != $id ) {
					push @need, $trackId;
				}
				elsif (!$trackId) {
					$log->warn("No id found: $trackURL");
				}
			
				# we can't fetch more than 50 at a time
				last if (scalar @need >= 50);
			}
		}
		
		if ( main::INFOLOG && $log->is_info ) {
			$log->info( "Need to fetch metadata for: " . join( ', ', @need ) );
		}
				
		if (scalar @need && $status) {
			_getBulkMetadata($client, $pagingCb, join( ',', @need ));
		} else {
			$client->master->pluginData(fetchingYTMeta => 0);
			
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );	
		} 
	};

	$client->master->pluginData(fetchingYTMeta => 1);
	
	# Need to start with current $id in case there is no YT active playlist
	_getBulkMetadata($client, undef, $id);
	
	# Then check the playlist (or terminate if empty)
	$pagingCb->(1);
	
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
		
		if (!$result || $result->{error} || !$result->{pageInfo}->{totalResults} ) {
			$log->error($result->{error} || 'Failed to grab track information');
			$cb->(0) if ($cb);
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
			main::DEBUGLOG && $log->debug("Duration: $duration");
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
			};
				
			$cache->set("yt:meta-" . $item->{id}, $meta, 86400);
		}				
			
		$cb->(1) if ($cb);
		
	}, $ids);
}


sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::YouTube::Plugin->_pluginDataFor('icon');
}



1;
