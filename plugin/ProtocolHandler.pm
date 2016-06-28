package Plugins::YouTube::ProtocolHandler;
use base qw(IO::Socket::SSL Slim::Formats::RemoteStream);

use strict;

use List::Util qw(min max first);
use HTML::Parser;
use URI::Escape;
use Scalar::Util qw(blessed);
use JSON::XS;
use Data::Dumper;
use File::Spec::Functions;
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'YouTube', 'lib');
use Digest::CRC qw(crc);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::YouTube::Signature;

use constant MAX_INBUF  => 102400;
use constant MAX_OUTBUF => 4096;
use constant MAX_READ   => 32768;
use constant EBML_NEED  => 12;

use constant ID_EBML			=> "\x1A\x45\xDF\xA3";
use constant ID_SEGMENT			=> "\x18\x53\x80\x67";
use constant ID_TRACKS 			=> "\x16\x54\xAE\x6B";
use constant ID_TRACK_ENTRY		=> "\xAE";
use constant ID_TRACK_NUM		=> "\xD7";
use constant ID_CODEC			=> "\x86";
use constant ID_CODEC_PRIVATE	=> "\x63\xA2";
use constant ID_CLUSTER			=> "\x1F\x43\xB6\x75";
use constant ID_BLOCK			=> "\xA3";
use constant ID_BLOCK_SIMPLE	=> "\xA3";
use constant ID_TIMECODE		=> "\xE7";

my $log   = logger('plugin.youtube');
my $prefs = preferences('plugin.youtube');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('youtube', __PACKAGE__);

sub flushCache { $cache->cleanup(); }

sub open {
	my $class = shift;
	my $args  = shift;
	my $url   = $args->{'url'} || '';
	
	$url =~ m|(?:https)://(?:([^\@:]+):?([^\@]*)\@)?([^:/]+):*(\d*)(\S*)|i;
	my ($server, $port, $path) = ($3, $4 || 443, $5);
	my $timeout = 10;
	
	if ($url !~ /^https/ || !$server || !$port) {

		$log->error("Couldn't find valid protocol, server or port in url: [$url]");
		return;
	}
	
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
	
	return $sock->request($args);
}


sub new {
	my $class = shift;
	my $args  = shift;
	my $song       = $args->{'song'};
	$args->{'url'} = $song->pluginData('stream');
	my $seekdata   = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};

	if (my $newtime = $seekdata->{'timeOffset'}) {

		$args->{'url'} .= "&t=" . int($newtime);
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
			'need'        => EBML_NEED,  #  minimum size of data to process
			'id'          => undef,   #  last EBML identifier
			'blocks'	  => 0,		  #  number of webm blocks
			'codec'		  => undef,	  #  codec
			'tracknum'    => 0,  	  #  track number to extract in stream
			'streaming'   => 1,       #  flag for streaming, changes to 0 when input socket closes
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

sub canSeek { 0 }

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
	
	$v->{'streaming'} &&= $self->processWebM;
	
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


sub processWebM {
	use bytes;

	my $self = shift;
	my $v = $self->vars;
	my $size;

	$log->debug('processing webm');
	
	while (1) {
		my $id = $v->{id};
		my $len;

		# output full, need to empty it a bit
		return 1 if (length($v->{'outBuf'}) >= MAX_OUTBUF);
			
		# fetch some more from input socket until we have moved too much			
		if (length($v->{'inBuf'}) < MAX_INBUF) {
		
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

					return 0 if (!length($v->{'inBuf'}));

				} else {

					$v->{'streamBytes'} += $bytes;
				}
			}
			
		}	
		
		$len = length $v->{inBuf};
			
		# need more data to do something
		next if ($v->{need} > $len);
		
		if (!defined $v->{id} && !$v->{demux}) {
			$len -= getEBML(\$v->{inBuf}, \$id, \$size);
		
			if ($id eq ID_CLUSTER && !defined $v->{codec}) {
				$log->error("no VORBIS codec found");
				return 0;
			}
						
			$v->{id} = $id;
			$v->{need} = $size;
		
			# handle all ID's whose size is the whole node and where a next ID is needed
			if ($id eq ID_SEGMENT || $id eq ID_TRACKS || $id eq ID_CLUSTER) {
				$v->{need} = EBML_NEED;				
				undef $v->{id};
				next;
			}
			
			if ($size > MAX_INBUF) {
				$log->error("EBML too large: $size");
				return 0;
			}
							
			if ($size > $len) {	next; }
		}
				
		#$log->error ("size: $size, len: $len, truelen: " . length($v->{inBuf}) . "need: ". $v->{need});				
		
		# handle ID's we care		
		if ($id eq ID_BLOCK || $id eq ID_BLOCK_SIMPLE) {
			my $time;
			
			$v->{blocks}++;
			my $out = extractVorbis(\$v->{inBuf}, $v->{codec}->{tracknum}, $size, \$time);
			
			if (defined $out) { 
				$v->{outBuf} .= buildOggPage([$out], $v->{timecode} + $time, 0x00, $v->{seqnum}++);
			}	
		} elsif	($id eq ID_TRACK_ENTRY) {
			my $codec =	getCodec(substr $v->{inBuf}, 0, $size);
			
			if (defined $codec) {
				$v->{codec} = $codec;
				$v->{outBuf} .= buildOggPage([$codec->{header}], 0, 0x02, $v->{seqnum}++);
				$v->{outBuf} .= buildOggPage([$codec->{setup}, $codec->{comment}], 0, 0x00, $v->{seqnum}++);
				${*$self}{'song'}->_playlist(0);
			}	
		} elsif ($id eq ID_TIMECODE) {
			$v->{timecode} = decode_u(substr($v->{inBuf}, 0, $size), $size);
			$log->debug("timecode: $v->{timecode}");
			#<>;
		}
				
		$v->{inBuf} = substr($v->{inBuf}, $size);
		$v->{need} = EBML_NEED;
		undef $v->{id};
				
	}	
}


sub buildOggPage {
	my ($packets, $time, $flags, $seq) = @_;
	my $count = 0;
	my $data = "";
	
	# 0-3:pattern 4:vers 5:flags 6-13:granule 14-17:serial num 18-21:seqno 22-25:CRC 26:Nseq 27...:segtable
	my $page = ("OggS" . "\x00" . pack("C", $flags) . 
				pack("V", $time) . "\x00\x00\x00\x00" . 
				"\x01\x00\x00\x00" . pack("V", $seq) . 
				"\x00\x00\x00\x00" . "\x00"
				);
			
	foreach my $p (@{$packets}) {
		my $len = length $p;
		while ($len >= 255) { $page .= "\xff"; $len -= 255; $count++ }
		$page .= pack("C", $len);
		$count++;
		$data .= $p;
	}		
	$page .= $data;
	
	substr($page, 26, 1, pack("C", $count));
	my $crc = crc($page, 32, 0, 0, 0, 0x04C11DB7, 0, 0);
	substr($page, 22, 4, pack("V", $crc));
	
	return $page;
}


sub getCodec {
	my $s = shift;
	my $codec;
	my $len = length $s;
	
	do {
		my ($id, $size);
	
		$len -= getEBML(\$s, \$id, \$size);
		if ($id eq ID_TRACK_NUM) {
			$codec->{tracknum} = decode_u(substr($s, 0, $size), $size);
			$log->debug("tracknum: $codec->{tracknum}");
		} elsif	($id eq ID_CODEC) {
			$codec->{id} = substr $s, 0, $size;
			$log->info("codec: $codec->{id}");
			return undef if ($codec->{id} ne "A_VORBIS");
		} elsif ($id eq ID_CODEC_PRIVATE) {
			my $count = decode_u8(substr $s, 0, 1) + 1;
			my $hdr_size = decode_u8(substr $s, 1, 1);
			my $set_size = decode_u8(substr $s, 2, 1);
			$log->info ("codec headers #:$count, hdr:$hdr_size, set:$set_size, total:$size");
									
			$codec->{header} = substr $s, 3, $hdr_size;
			$codec->{setup} = substr $s, 3 + $hdr_size, $set_size;
			$codec->{comment} = substr $s, 3 + $hdr_size + $set_size, $size - 3 - $set_size - $hdr_size;
		}	
		$s = substr $s, $size;
		$len -= $size;
	} while ($len);

	return $codec;
}

sub extractVorbis {
	my ($s, $tracknum, $size, $time) = @_;
	my $val = 0;
	my $len;
	
	my $c = decode_u8(substr($$s, 0, 1));
			
	for ($len = 1; !($c & 0x80); $len++) { 
		$c <<= 1; 
		$val = ($val << 8) + decode_u8(substr($val, $len-1, 1));
	}	
	
	$val = ($val << 8) + decode_u8(substr($$s, $len-1, 1));
	$val &= ~(1 << (7*$len));
	
	return undef if ($val != $tracknum);
	
	$$time = decode_u16(substr $$s, $len, 2);
	my $flags = decode_u8(substr $$s, $len + 2, 1);
	$log->debug("found track: $val (ts: $$time, flags: $flags)");
	
	if ($flags & 0x60) {
		$log->error("lacing trame, unsupported");
		return undef;
	}
		
	return substr($$s, $len + 2 + 1, $size - ($len + 2 + 1));
}

sub getEBML {
	my $in = shift;
	my $id = shift;
	my $size = shift;
	my ($len, $total);
	
	#get the element_id first
	my $c = decode_u8(substr($$in, 0, 1));
	
	for ($len = 1; !($c & 0x80); $len++) { $c <<= 1; }
	$$id = substr($$in, 0, $len);
	$$in = substr($$in, $len);
	$total = $len;
	
	# then get the data size
	$c = decode_u8(substr($$in, 0, 1));
	
	$$size = 0;
	for ($len = 1; !($c & 0x80); $len++) { 
		$c <<= 1; 
		$$size = ($$size << 8) + decode_u8(substr($$in, $len-1, 1));
	}	
	
	$$size = ($$size << 8) + decode_u8(substr($$in, $len-1, 1));
	$$size &= ~(1 << (7*$len));
	
	$log->debug("EBML : $$id, size:$$size (tagsize: $total + $len)");
	
	$$in = substr($$in, $len);
	$total += $len;
	
	return $total;
}


sub decode_u8  { unpack('C', $_[0]) }
sub decode_u16 { unpack('n', $_[0]) }
sub decode_u24 { unpack('N', ("\0" . $_[0]) ) }
sub decode_u32 { unpack('N', $_[0]) }
sub decode_u64 { unpack('Q', $_[0]) }
sub decode_u { 
	my ($s, $len) = @_;
	return unpack('C', $_[0]) if ($len == 1);
	return unpack('n', $_[0]) if ($len == 2);
	return unpack('N', ("\0" . $_[0]) ) if ($len == 3);
	return unpack('N', $_[0]) if ($len == 4);
	return unpack('Q', $_[0]) if ($len == 8);
	return undef;
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

			$log->debug($vars{url_encoded_fmt_stream_map});
			for my $stream (split(/,/, $vars{url_encoded_fmt_stream_map})) {
                no strict 'subs';
                my %props = map { split(/=/, $_) } split(/&/, $stream);

				# check streams in preferred id order
                #my @streamOrder = $prefs->get('prefer_lowbitrate') ? (5, 34) : (34, 35, 5);
				my @streamOrder = (43);

			    for my $id (@streamOrder) {
				$log->info("itag: $props{itag}");
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
											
					$log->info("sig $rawsig encrypted $encryptedsig");
					
					push @streams, { url => $url, format => $id == 43 ? 'ogg' : 'xxx',
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
			
			if ($song) {
				my $meta = $cache->get("yt:meta-$id");
				$song->track->secs($meta->{'duration'}) if $meta;
			}
		
			if ($client) {
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
			}	
			
			if (my $match = first { /$id/ } @need) { 
				my $meta = {
					type	=> 'YouTube',
					title	=> $url,
					icon	=> $icon,
					cover	=> $icon,
				};	
				$cache->set("yt:meta-" . $id, $meta, 86400);
			}
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
			
		$cb->(1) if ($cb);
		
	}, $ids);
}

sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::YouTube::Plugin->_pluginDataFor('icon');
}



1;
