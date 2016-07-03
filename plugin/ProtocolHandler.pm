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
use constant CHUNK_SIZE => 4096;	# MUST be less than MAX_READ

use constant ID_HEADER		=> "\x1A\x45\xDF\xA3";
use constant ID_SEGMENT		=> "\x18\x53\x80\x67";
use constant ID_INFO		=> "\x15\x49\xA9\x66";
use constant ID_TIMECODE_SCALE => "\x2A\xD7\xB1";
use constant ID_SEEKHEAD	=> "\x11\x4D\x9B\x74";
use constant ID_SEEK		=> "\x4D\xBB";
use constant ID_SEEK_ID		=> "\x53\xAB";
use constant ID_SEEK_POS	=> "\x53\xAC";
use constant ID_TRACKS 		=> "\x16\x54\xAE\x6B";
use constant ID_TRACK_ENTRY	=> "\xAE";
use constant ID_TRACK_NUM	=> "\xD7";
use constant ID_CODEC		=> "\x86";
use constant ID_CODEC_NAME	=> "\x25\x86\x88";
use constant ID_CODEC_PRIVATE	=> "\x63\xA2";
use constant ID_CLUSTER		=> "\x1F\x43\xB6\x75";
use constant ID_BLOCK		=> "\xA1";
use constant ID_BLOCK_SIMPLE	=> "\xA3";
use constant ID_TIMECODE	=> "\xE7";
use constant ID_CUES 		=> "\x1C\x53\xBB\x6B";
use constant ID_CUE_POINT	=> "\xBB";
use constant ID_CUE_TIME	=> "\xB3";
use constant ID_CUE_TRACK_POS	=> "\xB7";
use constant ID_CUE_TRACK	=> "\xF7";
use constant ID_CUE_CLUSTER_POS	=> "\xF1";

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
	${*$sock}{'startTime'} = $args->{'startTime'} || 0;
				
	return $sock->request($args);
}


sub new {
	my $class = shift;
	my $args  = shift;
	my $song       = $args->{'song'};
	$args->{'url'} = $song->pluginData('stream');
	my $seekdata   = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
  
	if (my $newtime = $seekdata->{'timeOffset'}) {
		$song->can('startOffset') ? $song->startOffset($newtime) : $song->{startOffset} = $newtime;
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $newtime);
		$args->{url} .= "&keepalive=yes";
		$args->{startTime} = $newtime;
	}
	
	$log->info("url: $args->{url}");
		
	my $self = $class->open($args);
		
	if (defined($self)) {
		${*$self}{'client'}  = $args->{'client'};
		${*$self}{'song'}    = $args->{'song'};
		${*$self}{'url'}     = $args->{'url'};
		${*$self}{'vars'} = {         # variables which hold state for this instance:
			#%{${*$self}{'vars'}},
			'inBuf'       => '',      #  buffer of received flv packets/partial packets
			'outBuf'      => '',      #  buffer of processed audio
			'id'          => undef,   #  last EBML identifier
			'need'        => EBML_NEED,  #  minimum size of data to process from Matroska file
			'position'    => 0,       #  byte position in Matroska stream/file
			'codec'		  => undef,	  #  codec
			'tracknum'    => 0,  	  #  track number to extract in stream
			'streaming'   => 1,       #  flag for streaming, changes to 0 when input socket closes
			'streamBytes' => 0,       #  total bytes received for stream
			'track'		  => undef,	  #  trackinfo
			'cue'		  => ${*$self}{'startTime'} != 0,		  #  cue required flag
			'seqnum'	  => 0,		  #  sequence number
			'offset'      => 0,       #  offset request from stream to be served at next possible opportunity
			'nextOffset'  => 0,       #  offset to apply to next GET
			'process'	  => 1,		  #  shall sysread data be processed or just forwarded ?
			'startTime'   => ${*$self}{'startTime'},
		};
	}
	
	return $self;
}

sub formatOverride {
	my $class = shift;
	my $song = shift;

	return $song->pluginData('format');
}


sub request {
	my $self = shift;
	my $args = shift;
	my $process = ${*$self}{vars}->{process} || 0;
	my $ret;
		
	${*$self}{vars}->{process} = 0;		
	$ret = $self->SUPER::request($args);
	${*$self}{vars}->{process} = $process;		
		
	return $ret;
}


sub requestString { 
	my $self = shift; 
	my $CRLF = "\x0D\x0A";
	my $v = $self->vars;
	my $offset = $v->{nextOffset} || 0;
	my $cue = (defined $v->{cue}) ? $v->{cue} : (${*$self}{startTime} || 0);
	
	$log->error("cue: $v->{cue}, ${*$self}{cue}");
		
	my @items = split(/$CRLF/, Slim::Player::Protocols::HTTP->requestString(@_));
	@items = grep { index($_, "Range:") } @items;
	if ($cue) { 
		@items = grep { index($_, "connection:") } @items;
		push @items, 'Connection: Keep-Alive'; 
		push @items, 'Range: bytes=' . $offset . '-' . ($offset + CHUNK_SIZE - 1);
	}
	else { push @items, 'Range: bytes=' . $offset . '-' }
	
	my $request = join($CRLF, @items);
	$request .= $CRLF . $CRLF;
	
	return $request;
}


sub isAudio { 1 }


sub parseHeaders {
	my ( $self,  @headers ) = @_;
	
	foreach my $header (@headers) {
	
		# Tidy up header to make no stray nulls or \n have been left by caller.
		$header =~ s/[\0]*$//;
		$header =~ s/\r/\n/g;
		$header =~ s/\n\n/\n/g;

		${*$self}{'redirect'} = $1 if ($header =~ /^Location:\s*(.*)/i);
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
	my $bytes;
	
	return $self->SUPER::sysread($_[1], $maxBytes) if (!$v->{process});
	
	while (length($v->{'inBuf'}) < MAX_INBUF && length($v->{'outBuf'}) < MAX_OUTBUF && $v->{streaming}) {
			
		$bytes = $self->SUPER::sysread($v->{'inBuf'}, MAX_READ, length($v->{'inBuf'}));
		next unless defined $bytes;
		
=comment		
		$log->error("processing webM");
		open (my $fh, '>', "d:/toto/webm");
		binmode $fh;
		print $fh $v->{inBuf};
		close $fh;
=cut		
		
		# process all we have in input buffer
		$v->{streaming} &&= $self->processWebM && $bytes;
		$v->{streamBytes} += $bytes;
		
		#$log->info("bytes: $bytes, streamBytes: $v->{streamBytes}");
		
		# Hope this work because when doing partial reponse (206) the whole request shall
		# be returned at once sysread as the CHUNK is s;aller than the MAX_READ. 
		# Otherwise need to find a way to detect when chubk is bigger than file and 
		# detecting $bytes == 0 does not work because the socket will be closed then
		# Probably parsing the HTTP response header in sysread would work
		if (($v->{streamBytes} == CHUNK_SIZE && $v->{cue}) || $v->{offset}) {
			#$log->error("GET again: next $v->{nextOffset} offset $v->{offset},  $v->{streaming}");
			if ($v->{offset}) {
				$v->{position} = $v->{nextOffset} = $v->{offset};
				$v->{inBuf} = "";
				$v->{offset} = 0;
				undef $v->{id};
			} 
			
			$v->{streamBytes} = 0;
			$v->{streaming} = 0 if (!$self->request({ url => ${*$self}{url} }));
			$v->{nextOffset} += CHUNK_SIZE;
		}
	}	
	
	#$log->info("loop streamBytes: $v->{streamBytes} inbuf:", length $v->{inBuf}, "outbuf:", length $v->{outBuf});
		
	my $len = length($v->{'outBuf'});

	if ($len > 0) {

		my $bytes = min($len, $maxBytes);

		$_[1] = substr($v->{'outBuf'}, 0, $bytes);

		$v->{'outBuf'} = substr($v->{'outBuf'}, $bytes);

		return $bytes;

	} elsif (!$v->{'streaming'}) {

		$log->info("stream ended $v->{streamBytes} bytes");

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
	my $self = shift;
	my $v = $self->vars;
	
	# process all we can ... might be over the MAX_OUTBUF
	while ($v->{need} <= length $v->{inBuf}) {
		my $id;
		my $size;
			
		# first need to acquired an ID	
		if (!defined $v->{id}) {
			$v->{position} += getEBML(\$v->{inBuf}, \$id, \$size);
							
			if ($id eq ID_CLUSTER && !defined $v->{track}) {
				$log->error("no VORBIS codec found");
				return 0;
			}
					
			# handle all ID's whose size is the whole node and where a next ID is needed
			if ($id eq ID_SEGMENT || $id eq ID_TRACKS || $id eq ID_CLUSTER) {
				$v->{segment_offset} = $v->{position} if ($id eq ID_SEGMENT);
				$log->info("cluster of $size byte (last audio $v->{timecode} ms)") if ($id eq ID_CLUSTER);
				next;
			} 
			
			$v->{id} = $id;
			$v->{need} = $size;
				
			if ($size > MAX_INBUF) {
				$log->error("EBML too large: $size");
				return 0;
			}
					
			next;
		}
		
		$id = $v->{id};
		$size = $v->{need};;
		
		# handle ID's we care		
		if ($id eq ID_INFO && $v->{cue}) {
			# starting from offset, need to get TRACKS directly
			$v->{timecode_scale} = getInfo(substr($v->{inBuf}, 0, $size), ID_TIMECODE_SCALE, "u");
			$log->info("track timecode scale: $v->{timecode_scale}");
			
			$v->{offset} = getSeekOffset($v->{seektable}, ID_TRACKS) + $v->{segment_offset};
			$log->info("tracks offset scale: $v->{offset}");
			#<>;
		} elsif ($id eq ID_SEEKHEAD && $v->{cue}) {
			# starting from offset, need to get INFO for timecodescale
			$v->{seektable} = substr $v->{inBuf}, 0, $size;
			$v->{offset} = getSeekOffset($v->{seektable}, ID_INFO) + $v->{segment_offset};
			$log->info("info offset: $v->{offset}");
			#<>;
		} elsif	($id eq ID_TRACK_ENTRY) {
			my $track =	getTrackInfo(substr $v->{inBuf}, 0, $size);
			$log->info("start time: $v->{startTime}");
			
			if (defined $track) {
				$v->{track} = $track;
				$v->{outBuf} .= buildOggPage([$track->{codec}->{header}], 0, 0x02, $v->{seqnum}++);
				$v->{outBuf} .= buildOggPage([$track->{codec}->{setup}, $track->{codec}->{comment}], 0, 0x00, $v->{seqnum}++);
				#${*$self}{'song'}->_playlist(0);
				# when starting from offset, need to cue to position
				if ($v->{cue}) {
					# got codec, but now needs to cue to the right position
					$v->{offset} = getSeekOffset($v->{seektable}, ID_CUES) + $v->{segment_offset};
					$log->info("cues offset: $v->{offset}");
					#<>;
				}
			}	
		} elsif ($id eq ID_TIMECODE) {
			$v->{timecode} = decode_u(substr($v->{inBuf}, 0, $size), $size);
			$log->debug("timecode: $v->{timecode}");
			#<>;
		} elsif ($id eq ID_BLOCK || $id eq ID_BLOCK_SIMPLE) {
			my $time;
			my $out = extractVorbis(\$v->{inBuf}, $v->{track}->{tracknum}, $size, \$time);
						
			if (defined $out) { 
				$v->{outBuf} .= buildOggPage([$out], $v->{timecode} + $time, 0x00, $v->{seqnum}++);
			}	
		} elsif ($id eq ID_CUES && $v->{cue}) {
			$v->{offset} = getCueOffset($v->{inBuf}, $v->{startTime}*($v->{timecode_scale}/1000000)*1000) + $v->{segment_offset};
			$v->{cue} = 0;
			$log->info("1st cluster offset: $v->{offset}");
			#<>;
		}
				
		$v->{inBuf} = substr($v->{inBuf}, $size);
		$v->{need} = EBML_NEED;
		$v->{position} += $size;
		undef $v->{id};
				
	}	
	
	return 1;
}


=comment
TimecodeScale 	2 [2A][D7][B1] 		f
=cut
sub getInfo {
	my ($s, $tag, $fmt) = @_;
	my ($id, $size);
		
	while (length $s) {
			
		getEBML(\$s, \$id, \$size);
		
		if ($id eq $tag) {
			if ($fmt eq "u") { return decode_u(substr($s, 0, $size), $size); }
			if ($fmt eq "f") { return decode_f(substr($s, 0, $size), $size); }
			if ($fmt eq "s") { return substr($s, 0, $size); }
		}	
		
		$s = substr($s, $size);
	}	
	
	return undef;
}


=comment
SeekHead 		1 [11][4D][9B][74]	m
Seek 			2 [4D][BB] 			m
SeekID 			3 [53][AB] 			b
SeekPosition 	3 [53][AC] 			u
=cut
sub getSeekOffset {
	my ($s, $tag) = @_;
	my ($id, $size);
		
	while (length $s) {
		my ($data, $seek_id);
		my $seek_offset = 0;
		
		getEBML(\$s, \$id, \$size);
		
		$data = substr($s, 0, $size);
		$s = substr($s, $size);
		
		next if ($id != ID_SEEK);
		
		while (length $data) {
			getEBML(\$data, \$id, \$size);
			$seek_id = substr($data, 0, $size) if ($id eq ID_SEEK_ID);
			$seek_offset = decode_u(substr($data, 0, $size), $size) if ($id eq ID_SEEK_POS);
			$data = substr($data, $size);
		} 
		
		return $seek_offset if ($seek_id eq $tag);
	} 
		
	return undef;
}

=comment
Cues 				1 [1C][53][BB][6B] 	m
CuePoint 			2 [BB] 				m
CueTime 			3 [B3] 				u
CueTrackPositions 	3 [B7] 				m
CueTrack 			4 [F7] 				u
CueClusterPosition 	4 [F1] 				u
=cut
sub getCueOffset {
	my ($s, $time) = @_;
	my ($id, $size);
	my $seek_offset;
		
	while (length $s) {
		my ($data, $cue_time, $cue_track);
		
		getEBML(\$s, \$id, \$size);
		
		$data = substr($s, 0, $size);
		$s = substr($s, $size);
		
		next if ($id != ID_CUE_POINT);
		
		while (length $data) {
			getEBML(\$data, \$id, \$size);
			$cue_time = decode_u(substr($data, 0, $size), $size) if ($id eq ID_CUE_TIME);
			$cue_track = substr($data, 0, $size) if ($id eq ID_CUE_TRACK_POS);
			$data = substr($data, $size);
		}
			
		next if ($cue_time < $time);

		while (length($cue_track) && !defined $seek_offset) {
			getEBML(\$cue_track, \$id, \$size);
			$seek_offset = decode_u(substr($cue_track, 0, $size), $size) if ($id eq ID_CUE_CLUSTER_POS);
			$cue_track = substr($cue_track, $size);
		}
		
		return $seek_offset;
	
	}	
		
	return undef;
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


=comment
Tracks 				1 [16][54][AE][6B] 		m
TrackEntry 			2 [AE] 					m
TrackNumber 		3 [D7] 					u
TrackUID 			3 [73][C5] 				u
TrackType 			3 [83] 					u
FlagEnabled 		3 [B9] 					u
FlagDefault 		3 [88] 					u
FlagForced 			3 [55][AA] 				u
FlagLacing 			3 [9C] 					u
MinCache 			3 [6D][E7] 				u
TrackTimecodeScale	3 [23][31][4F] 			f 
MaxBlockAdditionID 	3 [55][EE] 				u
CodecID 			3 [86					s
CodecPrivate 		3 [63][A2] 				b
=cut
sub getTrackInfo {
	my ($s, $scale) = @_;
	my ($info, $private);
	
	while (length $s) {
		my ($id, $size);
	
		getEBML(\$s, \$id, \$size);
				
		if ($id eq ID_TRACK_NUM) {
			$info->{tracknum} = decode_u(substr($s, 0, $size), $size);
			$log->info("tracknum: $info->{tracknum}");
		} elsif	($id eq ID_CODEC) {
			$info->{codec}->{id} = substr $s, 0, $size;
			$log->info("codec: $info->{codec}->{id}");
			return undef if ($info->{codec}->{id} ne "A_VORBIS");
		} elsif ($id eq ID_CODEC_PRIVATE) {
			$private = substr($s, 0, $size);
		}	
		$s = substr $s, $size;
	} 
	
	# codec private data shall only be used once we have found codec
	my $count = decode_u8(substr $private, 0, 1) + 1;
	my $hdr_size = decode_u8(substr $private, 1, 1);
	my $set_size = decode_u8(substr $private, 2, 1);
	$log->info ("private count $count, hdr: $hdr_size, setup: $set_size, total: ". length($private));
									
	# the explanation for the packet length & offsets of codec private data are found here
	# https://chromium.googlesource.com/webm/bindings/+/fb4fe6519b5812f1fac6ffe1fccf2c82f1ce7fdd/JNI/vorbis/vorbis_encoder.cc
	$info->{codec}->{header} = substr $private, 3, $hdr_size;
	$info->{codec}->{setup} = substr $private, 3 + $hdr_size, $set_size;
	$info->{codec}->{comment} = substr $private, 3 + $hdr_size + $set_size, length($private) - 3 - $set_size - $hdr_size;

	return $info;
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
	
	for ($len = 1; !($c & 0x80) && $len <= 4; $len++) { $c <<= 1 }
	
	if ($len == 5) {
		$log->error("wrong len: $len, $c");
		return undef;
	}
	
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
	
=comment	
	my $hex_id;
	$hex_id = decode_u8($$id) if ($total == 1);
	$hex_id = decode_u16($$id) if ($total == 2);
	$hex_id = decode_u24($$id) if ($total == 3);
	$hex_id = decode_u32($$id) if ($total == 4);
	printf ("id: %x ", $hex_id);
=cut	
	$log->debug("size:$$size (tagsize: $total + $len)");
	
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
sub decode_f { 
	my ($s, $len) = @_;
	return unpack('f', $_[0]) if ($len == 4);
	return unpack('d', $_[0]) if ($len == 8);
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
                my @streamOrder = (43, 44, 45, 46);

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
					
						push @streams, { url => $url, format => 'ogg',
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
