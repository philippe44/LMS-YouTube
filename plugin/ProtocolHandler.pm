package Plugins::YouTube::ProtocolHandler;
use base qw(IO::Socket::SSL Slim::Formats::RemoteStream);

use strict;

use List::Util qw(min max);
use HTML::Parser;
use URI::Escape;
use Scalar::Util qw(blessed);
use JSON::XS;
use Data::Dumper;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::YouTube::Signature;

use constant MAX_INBUF  => 102400;
use constant MAX_OUTBUF => 4096;
use constant MAX_READ   => 32768;

# streaming states
use constant HEADER     => 1;
use constant SIZE       => 2;
use constant TAG        => 3;
use constant AUDIO      => 4;
use constant DISCARD    => 5;

my $log   = logger('plugin.youtube');
my $prefs = preferences('plugin.youtube');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('youtube', __PACKAGE__);

sub flushCache { $cache->cleanup(); }

sub open {
	my $class = shift;
	my $args  = shift;
	my $url   = $args->{'url'} || '';
	
	my ($server, $port, $path) = Slim::Utils::Misc::crackURL($url);
	my $timeout = 10;

	if ($url !~ /^http/ || !$server || !$port) {

		$log->error("Couldn't find valid protocol, server or port in url: [$url]");
		return;
	}
	
	$port = 443 if $url =~ /^https:/;

	$log->info("Opening connection to $url: \n[$server on port $port with path $path with timeout $timeout]");

	my $sock = $class->SUPER::new(
		Timeout	  => $timeout,
		PeerAddr => $server,
		PeerPort => $port,
		SSL_startHandshake => 1,
	) or do {

		$log->error("Couldn't create socket binding to $main::localStreamAddr with timeout: $timeout - $!");
		return undef;
	};

	# store a IO::Select object in ourself.
	# used for non blocking I/O
	${*$sock}{'_sel'} = IO::Select->new($sock);
	${*$sock}{'song'} = $args->{'song'};
	
	#$log->debug("in open ref sock: ", ref $sock, "(D)", Dumper($sock));
	#$log->debug("in open ref class: ", ref $class, "(D)", Dumper($class));

=comment
	#this is proven to work, the socket is open and connected
	my $c;
	print $sock "HEAD / HTTP/1.0\r\n\r\n";
	while (!$c) {
		$sock->SUPER::sysread($c, 10);
	}
	$log->info("test string: $c");
=cut

	return $sock->request($args);

}


sub new {
	my $class = shift;
	my $args  = shift;
	my $song       = $args->{'song'};
	$args->{'url'} = $song->pluginData('stream');
	my $seekdata   = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};

	if (my $newtime = $seekdata->{'timeOffset'}) {

		$args->{'url'} .= "&begin=" . int($newtime * 1000);
		$song->can('startOffset') ? $song->startOffset($newtime) : $song->{startOffset} = $newtime;
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
	}

	$log->info("url: $args->{url}");
		
	#$log->debug("in new class ref: ", ref $class);
	my $self = $class->open($args);
	#$log->debug("in new ref class: ", ref $self, "(D)", Dumper($self));

	if (defined($self)) {
		${*$self}{'client'}  = $args->{'client'};
		${*$self}{'song'}    = $args->{'song'};
		${*$self}{'url'}     = $args->{'url'};
		${*$self}{'vars'} = {         # variables which hold state for this instance:
			'inBuf'       => '',      #  buffer of received flv packets/partial packets
			'outBuf'      => '',      #  buffer of processed audio
			'next'        => HEADER,  #  expected protocol fragment
			'streaming'   => 1,       #  flag for streaming, changes to 0 when input socket closes
			'tagSize'     => undef,   #  size of tag expected
			'adtsbase'    => undef,   #  base for adts output header
			'count'       => 0,       #  number of tags processed
			'seenaudio'   => 0,       #  whether audio has been seen (close stream if not seen within 10 tags)
			'audioBytes'  => 0,       #  audio bytes extracted
			'streamBytes' => 0,       #  total bytes received for stream
		};
	}

	return $self;
}

sub formatOverride {
	my $class = shift;
	my $song = shift;

	return $song->pluginData('format') || 'aac';
}

sub isAudio { 1 }

sub requestString { 
	shift; 
	Slim::Player::Protocols::HTTP->requestString(@_);
}

sub parseHeaders {
	my ( $self,  @headers ) = @_;
	
	foreach my $header (@headers) {
	
		# Tidy up header to make no stray nulls or \n have been left by caller.
		$header =~ s/[\0]*$//;
		$header =~ s/\r/\n/g;
		$header =~ s/\n\n/\n/g;

		if ($header =~ /^Location:\s*(.*)/i) {
				${*$self}{'redirect'} = $1;
		}
	}
}

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
	
	if (!$v) {
		my $nb = $self->SUPER::sysread($_[1], $maxBytes);
		return $nb;
	}	
	
	$v->{'streaming'} &&= $self->processFLV;
	
	my $len = length($v->{'outBuf'});

	if ($len > 0) {

		my $bytes = min($len, $maxBytes);

		$_[1] = substr($v->{'outBuf'}, 0, $bytes);

		$v->{'outBuf'} = substr($v->{'outBuf'}, $bytes);

		return $bytes;

	} elsif (!$v->{'streaming'}) {

		$log->debug("stream ended");

		$self->close;

		return 0;

	} elsif (!$self->connected) {

		$log->debug("input socket not connected");

		$self->close;

		return 0;

	} else {

		$! = EWOULDBLOCK;
		return undef;
	}
}


sub processFLV {
	use bytes;

	my $self = shift;
	my $v = $self->vars;

	$log->debug('processing FLV');
	
	while (1) {

		# fetch some more from input socket until we have moved too much
		if (length($v->{'inBuf'}) < MAX_INBUF && length($v->{'outBuf'}) < MAX_OUTBUF) {

			my $bytes = $self->SUPER::sysread($v->{'inBuf'}, MAX_READ, length($v->{'inBuf'}));

			if (defined $bytes) {

				if ($bytes == 0) {

					if ($log->is_debug) {
						if (my $duration = ${*$self}{'song'}->track->secs) {
							my $audio = int($v->{'audioBytes'} * 8 / $duration / 1000);
							my $total = int($v->{'streamBytes'} * 8 / $duration / 1000);
							$log->debug("stream ended - audio: $v->{audioBytes} bytes $audio kbps, " .
										"stream: $v->{streamBytes} bytes $total kbps");
						} else {
							$log->debug("stream ended");
						}
					}

					return 0;

				} else {

					$v->{'streamBytes'} += $bytes;
				}
			}
		}

		my $len = length($v->{'inBuf'});
		my $next = $v->{'next'};

		if ($next == HEADER && $len >= 9) {

			my $sig    = substr($v->{'inBuf'}, 0, 3);
			my $version= decode_u8(substr($v->{'inBuf'}, 3, 1));
			my $flags  = decode_u8(substr($v-{'inBuf'}, 4, 1));
			my $offset = decode_u32(substr($v->{'inBuf'}, 5, 4));
			my $audio  = $flags & 0x04 ? 1 : 0;
			my $video  = $flags & 0x01 ? 1 : 0;

			if ($sig ne 'FLV' && $version != 1) {
				$log->info("non FLV stream sig: $sig version: $version - closing");
				return 0;
			}

			$log->info("Header: sig: $sig version: $version flags: $flags (audio: $audio video: $video) offset: $offset");

			$v->{'inBuf'} = substr($v->{'inBuf'}, $offset);
			$v->{'next'}  = SIZE;

		} elsif ($next == SIZE && $len >= 4) {

			#my $size = decode_u32(substr($v->{'inBuf'}, 0, 4));

			$v->{'inBuf'} = substr($v->{'inBuf'}, 4);
			$v->{'next'}  = TAG;

		} elsif ($next == TAG && $len >= 11) {

			my $flags = decode_u8(substr($v->{'inBuf'}, 0, 1));
			my $filter= $flags & 0x20 ? 1 : 0;
			my $type  = $flags & 0x1f;
			my $size  = decode_u24(substr($v->{'inBuf'}, 1, 3));

			$log->debug("Tag Header: flags: $flags filt: $filter type: $type size: $size");

			$v->{'tagSize'} = $size;
			$v->{'inBuf'} = substr($v->{'inBuf'}, 11);
			$v->{'next'}  = ($type == 8) ? AUDIO : DISCARD;

			if ($size > MAX_INBUF) {
				$log->error("tag size: $size greater than max: " . MAX_INBUF . " - closing stream");
				return 0;
			}

			if (!$v->{'audioseen'} && $v->{'count'}++ > 10) {
				$log->info("closing stream - no audio");
				return 0;
			}

		} elsif ($next == DISCARD && $len >= $v->{'tagSize'}) {

			# discard as non audio tag
			$v->{'inBuf'} = substr($v->{'inBuf'}, $v->{'tagSize'});
			$v->{'next'}  = SIZE;

		} elsif ($next == AUDIO && $len >= $v->{'tagSize'}) {

			my $firstword = decode_u32(substr($v->{'inBuf'}, 0, 4));

			if (($firstword & 0xFFFF0000) == 0xAF010000) {      # AAC audio data

				$log->debug("AAC Audio");

				my $header = $v->{'adtsbase'};

				# add framesize dependant portion
				my $framesize = $v->{'tagSize'} - 2 + 7;
				$header |= (
					"\x00\x00\x00" .
						chr( (($framesize >> 11) & 0x03) ) .
						chr( (($framesize >> 3)  & 0xFF) ) .
						chr( (($framesize << 5)  & 0xE0) )
				);

				# add header and data to output buf
				$v->{'outBuf'} .= $header;
				$v->{'outBuf'} .= substr($v->{'inBuf'}, 2, $v->{'tagSize'} - 2);

				$v->{'audioBytes'} += $v->{'tagSize'} - 2;

				$v->{'audioseen'} ||= do {
					$log->debug("audio seen");
					${*$self}{'song'}->_playlist(0);
					1;
				};

			} elsif (($firstword & 0xFFFF0000) == 0xAF000000) { # AAC Config

				$log->debug("AAC Config");

				my $profile  = 1; # hard code to 1 rather than ($firstword & 0x0000f800) >> 11;
				my $sr_index = ($firstword & 0x00000780) >>  7;
				my $channels = ($firstword & 0x00000078) >>  3;

				$v->{'adtsbase'} =
					chr( 0xFF ) .
					chr( 0xF9 ) .
					chr( (($profile << 6) & 0xC0) | (($sr_index << 2) & 0x3C) | (($channels >> 2) & 0x1) ) .
					chr( (($channels << 6) & 0xC0) ) .
					chr( 0x00 ) .
					chr( ((0x7FF >> 6) & 0x1F) ) .
					chr( ((0x7FF << 2) & 0xFC) );

			} elsif (($firstword & 0xF0000000) == 0x20000000) { # MP3 Audio

				$log->debug("MP3 Audio");

				$v->{'outBuf'} .= substr($v->{'inBuf'}, 1, $v->{'tagSize'} - 1);
				$v->{'audioBytes'} += $v->{'tagSize'} - 1;

				$v->{'audioseen'} ||= do {
					$log->debug("audio seen");
					${*$self}{'song'}->_playlist(0);
					1;
				};
			}

			$v->{'inBuf'} = substr($v->{'inBuf'}, $v->{'tagSize'});
			$v->{'next'}  = SIZE;

		} else {

			# can't process any more at present
			return 1;
		}
	}
}

sub decode_u8  { unpack('C', $_[0]) }
sub decode_u16 { unpack('n', $_[0]) }
sub decode_u24 { unpack('N', ("\0" . $_[0]) ) }
sub decode_u32 { unpack('N', $_[0]) }

sub getId {
	my ($class, $url) = @_;

	$url .= '&';
	## also youtube://http://www youtube com/watch?v=tU0_rKD8qjw
		
	if ($url =~ /^(?:youtube:\/\/)?https?:\/\/www\.youtube\.com\/watch\?v=(.*)&/ || 
		$url =~ /^youtube:\/\/www\.youtube\.com\/v\/(.*)&/ ||
		$url =~ /^youtube:\/\/(.*)&/) {
	
		return $1;
	}
	
	return undef;
}

# repeating stream to move onto next playable url until one is found
# use a hack above to mark song as non playlist once one stream has found a playable audio stream
sub isRepeatingStream { 1 }

# fetch the YouTube player url and extract a playable stream
sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	$log->debug('getNextTrack');
	# play url from previously fetched list if we have yet to find a playable stream
	if ($song->pluginData('streams')) {
		if (my $streamInfo = shift @{$song->pluginData('streams')}) {
			$song->pluginData(stream => $streamInfo->{'url'});
			$song->pluginData(format => $streamInfo->{'format'});
			$successCb->();
		} else {
			$errorCb->("no more streams");
		}
		return;
	}

	my $masterUrl = $song->track()->url;
	my $client    = $song->master();
	my $id = $class->getId($masterUrl);
	my $url = "http://www.youtube.com/watch?v=$id";

	$log->info("next track id: $id url: $url master: $masterUrl");

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
                # New web page layout uses HTML5 details
				#FIXME: seems that v0.16 did change for regex here
				#($vars{url_encoded_fmt_stream_map}) = ($http->content =~ /\"url_encoded_fmt_stream_map\":\s*\"(.*?)\"/);
                ($vars{url_encoded_fmt_stream_map}) = ($http->content =~ /\"url_encoded_fmt_stream_map\":\"(.*?)\"/);

                # Replace known unicode characters
                $vars{url_encoded_fmt_stream_map} =~ s/\\u0026/\&/g;
                #$vars{url_encoded_fmt_stream_map} =~ s/sig=/signature=/g;
                $log->debug("url_encoded_fmt_stream_map: $vars{url_encoded_fmt_stream_map}");
            }
						
			if (!defined $vars{player_url}) {
				($vars{player_url}) = ($http->content =~ /"assets":.+?"js":\s*("[^"]+")/);

				if ($vars{player_url}) { 
					#FIXME
					#$vars{player_url} = decode_json($vars{player_url}, {allow_nonref=>1});
					$vars{player_url} = JSON::XS->new->allow_nonref(1)->decode($vars{player_url});
					if ($vars{player_url} =~ m,^//,) {
						$vars{player_url} = "https:" . $vars{player_url};
					} elsif ($vars{player_url} =~ m,^/,) {
						$vars{player_url} = "https://www.youtube.com" . $vars{player_url};
					}
				}
				$log->debug("player_url: $vars{player_url}");
			}

            for my $stream (split(/,/, $vars{url_encoded_fmt_stream_map})) {
                no strict 'subs';
                my %props = map { split(/=/, $_) } split(/&/, $stream);

				# check streams in preferred id order
                my @streamOrder = $prefs->get('prefer_lowbitrate') ? (5, 34) : (34, 35, 5);

                for my $id (@streamOrder) {
                if ($id == $props{itag}) {
					$log->debug("props: $props{url}");
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
											
					$log->debug("sig $rawsig encrypted $encryptedsig");
					
					push @streams, { url => $url, format => $id == 5 ? 'mp3' : 'aac',
								 rawsig => $rawsig, encryptedsig => $encryptedsig };
				}
			}
        }

		# play the first stream
		if (my $streamInfo = shift @streams) {
			my $sig;
			my $proceed = 1;
					
			if ($streamInfo->{'encryptedsig'}) {
				if ($vars{player_url}) {
					if (Plugins::YouTube::Signature::has_player($vars{player_url})) {
					    $log->debug("Using cached player $vars{player_url}");
					    $sig = Plugins::YouTube::Signature::unobfuscate_signature(
										$vars{player_url}, $streamInfo->{'rawsig'} );
							
					    $log->debug("Unobfuscated signature (cached) $sig");
					} else {
					    $log->debug("Fetching new player $vars{player_url}");
						$proceed = 0;
						
					    Slim::Networking::SimpleAsyncHTTP->new(
							sub {
								my $http = shift;
								my $jscode = $http->content;

								eval {
									Plugins::YouTube::Signature::cache_player($vars{player_url}, $jscode);
									$log->debug("Saved new player $vars{player_url}");
								};
								if ($@) {
									$errorCb->("cannot load player code: $@");
									return;
								}
								my $sig = Plugins::YouTube::Signature::unobfuscate_signature(
											$vars{player_url}, $streamInfo->{'rawsig'} );
								$log->debug("Unobfuscated signature $sig");
								$song->pluginData(streams => \@streams);	
								$song->pluginData(stream  => $streamInfo->{'url'} . "&signature=" . $sig);
								$song->pluginData(format  => $streamInfo->{'format'});
								$class->getMetadataFor($client, $masterUrl, undef, $song);
								$successCb->();
							},
						
							sub {
								$log->debug("Cannot fetch player " . $_[1]);
								$errorCb->("cannot fetch player code");
							},
					
						)->get($vars{player_url});
					}
				} else {
					    $log->debug("No player url to unobfuscat signature");
						$errorCb->("no player url found");
						$proceed = 0;
				}
				
			} else {
				$log->debug("raw signature $sig");
			    $sig = $streamInfo->{'rawsig'};
			}
			
			if ($proceed) {
				$song->pluginData(streams => \@streams);	
				$song->pluginData(stream  => $streamInfo->{'url'} . "&signature=" . $sig);
				$song->pluginData(format  => $streamInfo->{'format'});
				$class->getMetadataFor($client, $masterUrl, undef, $song);
				$successCb->();
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

sub suppressPlayersMessage {
	my ($class, $client, $song, $string) = @_;

	# suppress problem opening message if we have more streams to try
	if ($string eq 'PROBLEM_OPENING' && scalar @{$song->pluginData('streams') || []}) {
		return 1;
	}

	return undef;
}

sub getMetadataFor {
	my ($class, $client, $url, undef, $song) = @_;
	my $icon = $class->getIcon();
	
	main::DEBUGLOG && $log->debug("getmetadata: $url");
		
	my $id = $class->getId($url) || return {};
	
	if (my $meta = $cache->get("yt:meta-$id")) {
		$song->track->secs($meta->{'duration'}) if $song;
				
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
	
	$client->master->pluginData(fetchingYTMeta => 1);

	my $pageCb;
	
	# Go fetch metadata for all tracks on the playlist without metadata
	$pagingCb = sub {
		my ($status) = @_;
		my @need;
		
		for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
			my $trackURL = blessed($track) ? $track->url : $track;
			if ( $trackURL =~ m{youtube:/*(.+)} ) {
				my $id = $class->getId($trackURL);
				if ( $id && !$cache->get("yt:meta-$id") ) {
					push @need, $id;
				}
				elsif (!$id) {
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
			
			if ($song) {
				my $meta = $cache->get("yt:meta-$id");
				$song->track->secs($meta->{'duration'}) if $meta;
			}
		
			if ($client) {
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
			}	
		}	
	};

	$client->master->pluginData(fetchingYTMeta => 1);
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
			$cb->(0);
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
			main::INFOLOG && $log->info("Duration: $duration");
			my ($misc, $hour, $min, $sec) = $duration =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/;
			$duration = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);
									
			if ($duration && $title) {
				my $meta = {
					title    =>	$title,
					artist   => $artist,
					duration => $duration,
					icon     => $icon,
					cover    => $cover || $icon,
					type     => 'YouTube',
				};
	
				$meta->{_fulltitle} = $fulltitle;
				$cache->set("yt:meta-" . $item->{id}, $meta, 86400);
			
			}
		}				
			
		$cb->(1);
		
	}, $ids);
}

sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::YouTube::Plugin->_pluginDataFor('icon');
}



1;
