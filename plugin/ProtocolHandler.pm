package Plugins::YouTube::ProtocolHandler;
use base qw(IO::Socket::SSL Slim::Formats::RemoteStream);

use strict;

use List::Util qw(min max);
use HTML::Parser;
use URI::Escape;
use XML::Simple;
use Data::Dumper;
use JSON::XS;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

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

my %fetching; # hash of ids we are fetching metadata for to avoid multiple fetches

Slim::Player::ProtocolHandlers->registerHandler('youtube', __PACKAGE__);

sub crackURL {
	my ($string) = @_;

	my $urlstring = "https";

	$string =~ m|(?:$urlstring)://(?:([^\@:]+):?([^\@]*)\@)?([^:/]+):*(\d*)(\S*)|i;
		
	my ($user, $pass, $host, $port, $path) = ($1, $2, $3, $4, $5);

	$path ||= '/';
	$port ||= 443;
	
	return ($host, $port, $path, $user, $pass);
}

sub open {
	my $class = shift;
	my $args  = shift;

	my $url   = $args->{'url'};

	my ($server, $port, $path, $user, $password) = crackURL($url);

	if (!$server || !$port) {

		$log->error("Couldn't find server or port in url: [$url]");
		return;
	}

	my $timeout = 15;
	
	$log->info("Opening connection to $url: [$server on port $port with path $path with timeout $timeout]");

	my $sock = $class->SUPER::new(
		Timeout	  => $timeout,
		PeerAddr => $server,
		PeerPort => $port,
		SSL_startHandshake => 1,
		SSL_verify_mode => 'SSL_VERIFY_NONE',
	
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

#sub request { shift; Slim::Formats::RemoteStream->request(@_) }

sub parseHeaders {}

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
	#$log->debug("in sysread class ref: ", ref $self, " (D) => ", Dumper($self));

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

sub _id {
	my ($class, $url) = @_;

	$url .= '&';
	## also youtube://http://www youtube com/watch?v=tU0_rKD8qjw
		
	if ($url =~ /^youtube:\/\/https?:\/\/www\.youtube\.com\/watch\?v=(.*)&/ || 
		$url =~ /^youtube:\/\/www\.youtube\.com\/v\/(.*)&/ ||
		$url =~ /^youtube:\/\/(.*)&/) {
	#if ($url =~ /^youtube:\/\/www\.youtube\.com\/v\/(.*)&/) {
		$log->debug("parsed id: $url");
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
	$log->info("master fetching: $masterUrl");
	my $client    = $song->master();

	my $id = $class->_id($masterUrl);

	my $url = "http://www.youtube.com/watch?v=$id";

	$log->info("fetching: $id $url");

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
                            ($vars{url_encoded_fmt_stream_map}) = ($http->content =~ /\"url_encoded_fmt_stream_map\":\"(.*?)\"/);

                            # Replace known unicode characters
                            $vars{url_encoded_fmt_stream_map} =~ s/\\u0026/\&/g;
                            $vars{url_encoded_fmt_stream_map} =~ s/sig=/signature=/g;
                            $log->debug("url_encoded_fmt_stream_map: $vars{url_encoded_fmt_stream_map}");
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
											$url .="&signature=$props{signature}";

                                            push @streams, { url => $url, format => $id == 5 ? 'mp3' : 'aac' };
                                    }
                            }

                        }

			# play the first stream
			if (my $streamInfo = shift @streams) {
				$song->pluginData(streams => \@streams);
				$song->pluginData(stream  => $streamInfo->{'url'});
				$song->pluginData(format  => $streamInfo->{'format'});
				# ensure we fetch metadata for this stream
				$class->getMetadataFor(undef, $masterUrl, undef, $song);
				$successCb->();
			} else {
				$errorCb->("no streams found");
			}
		},

		sub {
			$errorCb->($_[1]);
		},

	)->get($url);
	
	$log->debug("getNextTrack url: $url");
}

sub suppressPlayersMessage {
	my ($class, $client, $song, $string) = @_;

	# suppress problem opening message if we have more streams to try
	if ($string eq 'PROBLEM_OPENING' && scalar @{$song->pluginData('streams') || []}) {
		return 1;
	}

	return undef;
}


sub getMetadataForV2 {
	my ($class, undef, $url, undef, $song, $cb) = @_;

	my $id = $class->_id($url) || return {};
	
	
	my $cache = Slim::Utils::Cache->new;
	

	if (my $meta = $cache->get("yt:meta-$id")) {
		if ($song) {
			$song->track->title($meta->{'title'});
			$song->track->secs($meta->{'duration'});
			Plugins::YouTube::Plugin->updateRecentlyPlayed({
				url => $url, name => $meta->{_fulltitle} || $meta->{title}, icon => $meta->{icon}
			});
		}
		if ($cb) {
			$cb->($meta);
			return undef;
		}
		return $meta;
	}

	if ($fetching{$id} && !defined $cb) {
		$log->debug("already fetching metadata for $id");
		return {}
	}

	
	
	
	$log->info("fetching metadata for $id");
	
	

	Slim::Networking::SimpleAsyncHTTP->new(

		sub {
			my $http = shift;

			
			### it now in json form
			
			my $xml  = eval { XMLin($http->content) };

			delete $fetching{$id};

			if ($@) {
				$log->warn($@);
			}

			my $cover; my $icon;

			for my $image (@{$xml->{'media:group'}->{'media:thumbnail'}}) {
				$icon  = $image->{'url'} if $image->{'yt:name'} eq 'default';
				$cover = $image->{'url'} if $image->{'yt:name'} eq 'hqdefault';
			}

			my $title  = $xml->{'title'};
			my $artist = $xml->{'author'}->{'name'};
			my $fulltitle;

			if ($title =~ /(.*) - (.*)/) {
				$fulltitle = $title;
				$artist = $1;
				$title  = $2;
			}

			if ($xml) {
				my $meta = {
					title    =>	$title,
					artist   => $artist,
					duration => $xml->{'media:group'}->{'yt:duration'}->{'seconds'},
					icon     => $icon,
					cover    => $cover || $icon,
					type     => 'YouTube',
				};

				$meta->{_fulltitle} = $fulltitle if $fulltitle;

				if ($song) {
					$song->track->title($meta->{'title'});
					$song->track->secs($meta->{'duration'});
					Plugins::YouTube::Plugin->updateRecentlyPlayed({ url => $url, name => $fulltitle || $title, icon => $icon });
				}

				$cache->set("yt:meta-$id", $meta, 86400);

				if ($cb) {
					$cb->($meta);
					return;
				}
			}
		},

		sub {
			$log->warn("error: $_[1]");
			delete $fetching{$id};
			if ($cb) {
				$cb->({});
			}
		},


	)->get("http://gdata.youtube.com/feeds/api/videos/$id?v=2");
	
	$fetching{$id} = 1;

	return undef if ($cb);

	return {};
}


sub getMetadataFor {
	my ($class, undef, $url, undef, $song, $cb) = @_;

	$log->debug("getmetadata: $url");
	#return {};
	
	my $id = $class->_id($url) || return {};
	
	###Plugins::YouTube::Plugin::_debug(['vurl',$id,$url]);return {};

	my $cache = Slim::Utils::Cache->new;
	##Plugins::YouTube::Plugin::_debug(['vurl',$id,$cache->get("yt:meta-$id")]); return {};
	if (my $meta = $cache->get("yt:meta-$id")) {
		if ($song) {
			$song->track->title($meta->{'title'});
			$song->track->secs($meta->{'duration'});
			Plugins::YouTube::Plugin->updateRecentlyPlayed({
				url => $url, name => $meta->{_fulltitle} || $meta->{title}, icon => $meta->{icon}
			});
		}
		if ($cb) {
			$cb->($meta);
			return undef;
		}
		return $meta;
	}

	if ($fetching{$id} && !defined $cb) {
		$log->debug("already fetching metadata for $id");
		return {}
	}
	
	###part=contentDetails&id=$vId&key=dldfsd981asGhkxHxFf6JqyNrTqIeJ9sjMKFcX4");

	my $vurl = $prefs->get('APIurl') . "/videos/?part=snippet,contentDetails&id=$id&key=" .$prefs->get('APIkey');

	$log->info("fetching metadata for $id");
	
	###Plugins::YouTube::Plugin::_debug(['vurl',$id,$vurl]);return {};

	Slim::Networking::SimpleAsyncHTTP->new(

		sub {
			my $http = shift;
			
			### it now in json form
			
			my $json = eval { decode_json($http->content) };
				
			###$log->warn("json::" . $http->content);

			
			
			if ($@) {
				$log->warn($@);
			}
			

			delete $fetching{$id};

			

			my $cover; my $icon;
			
			### all are in 'items'->[0]
			
			my $vdetail = $json->{items}->[0] or return;
			
			my $snippet=$vdetail->{snippet} or return;
			
			$icon = $snippet->{thumbnails}->{default}->{url};
			$cover = $snippet->{thumbnails}->{high}->{url};


			my $title  = $snippet->{'title'};
			my $artist = "";###$xml->{'author'}->{'name'};
			my $fulltitle;

			if ($title =~ /(.*) - (.*)/) {
				$fulltitle = $title;
				$artist = $1;
				$title  = $2;
			}
			my $duration=$vdetail->{contentDetails}->{duration};
			if ($duration && $title) {
				my $meta = {
					title    =>	$title,
					artist   => $artist,
					duration => $duration,
					icon     => $icon,
					cover    => $cover || $icon,
					type     => 'YouTube',
				};

				$meta->{_fulltitle} = $fulltitle if $fulltitle;

				if ($song) {
					$song->track->title($meta->{'title'});
					$song->track->secs($meta->{'duration'});
					Plugins::YouTube::Plugin->updateRecentlyPlayed({ url => $url, name => $fulltitle || $title, icon => $icon });
				}

				$cache->set("yt:meta-$id", $meta, 86400);

				if ($cb) {
					$cb->($meta);
					return;
				}
			}
		},

		sub {
			$log->warn("error: $_[1]");
			delete $fetching{$id};
			if ($cb) {
				$cb->({});
			}
		},

	)->get($vurl);

	## v2
	##http://gdata.youtube.com/feeds/api/videos/$id?v=2
	###$prefs->get('APIkey')
	$fetching{$id} = 1;

	$log->debug("getMetaDataFor vurl: $vurl");
	return undef if ($cb);

	return {};
}

1;
