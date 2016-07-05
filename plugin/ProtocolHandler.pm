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

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::YouTube::Signature;

use constant MAX_INBUF  => 102400;
use constant MAX_OUTBUF => 4096;
use constant MAX_READ   => 32768;
use constant EBML_NEED  => 12;
use constant CHUNK_SIZE => 8192;	# MUST be less than MAX_READ

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
				
	return $sock->request($args);
}


sub new {
	my $class = shift;
	my $args  = shift;
	my $song       = $args->{'song'};
	$args->{'url'} = $song->pluginData('stream');
	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'};
  
	if ($startTime) {
		$song->can('startOffset') ? $song->startOffset($startTime) : $song->{startOffset} = $startTime;
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $startTime);
		$args->{url} .= "&keepalive=yes";
	}
	
	$log->info("url: $args->{url}");
		
	my $self = $class->open($args);
		
	if (defined($self)) {
		${*$self}{'client'}  = $args->{'client'};
		${*$self}{'song'}    = $args->{'song'};
		${*$self}{'url'}     = $args->{'url'};
		${*$self}{'vars'} = {         # variables which hold state for this instance:
			%{${*$self}{'vars'}},
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
			'cue'		  => $startTime != 0,		  #  cue required flag
			'seqnum'	  => 0,		  #  sequence number
			'offset'      => 0,       #  offset request from stream to be served at next possible opportunity
			'nextOffset'  => CHUNK_SIZE,       #  offset to apply to next GET
			'process'	  => 1,		  #  shall sysread data be processed or just forwarded ?
			'startTime'   => $startTime, # not necessary, avoid use in processWebM knows of owner's data
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
	my ($self, $client, $url, $post, $seekdata) = @_;
	my $CRLF = "\x0D\x0A";
	my $v = $self->vars;
	my $offset = $v->{nextOffset} || 0;
	my $cue = 0;
	
	$cue = $seekdata->{timeOffset} if (defined $seekdata);
	$cue = $v->{cue} if (defined $v->{cue});
	
	main::INFOLOG && $log->info("cue: $v->{cue}, time: ", ($seekdata) ? $seekdata->{timeOffset} : "");

	my @items = split(/$CRLF/, Slim::Player::Protocols::HTTP->requestString($client, $url, $post, $seekdata));
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
		
		${*$self}{'contentLength'} = $1 if ( $header =~ /^Content-Length:\s*([0-9]+)/i );
		${*$self}{'redirect'} = $1 if ( $header =~ /^Location:\s*(.*)/i );
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
	
	#while (length($v->{'inBuf'}) < MAX_INBUF && length($v->{'outBuf'}) < MAX_OUTBUF && $v->{streaming}) {
	while (!length($v->{'outBuf'}) && $v->{streaming}) {
			
		$bytes = $self->SUPER::sysread($v->{'inBuf'}, MAX_READ, length($v->{'inBuf'}));
		next unless defined $bytes;
		
=comment		
		$log->error("processing webM");
		open (my $fh, '>', "d:/toto/webm");
		binmode $fh;
		print $fh $v->{inBuf};
		close $fh;
=cut		
		
		$log->info("content length: ${*$self}{'contentLength'}") if ( $v->{streamBytes} == 0 );
			
		# process all we have in input buffer
		$v->{streaming} &&= $self->processWebM && $bytes;
		$v->{streamBytes} += $bytes;
		
		#$log->info("bytes: $bytes, streamBytes: $v->{streamBytes}");
		
		# GET more data if needed, move to a different offset or force finish if we have started from an offset
		if ( $v->{streamBytes} == ${*$self}{contentLength} ) {
			my $proceed = $v->{cue} || $v->{offset};
			
			# Must test offset first as it is not exclusive with cue but takes precedence
			if ( $v->{offset} ) {
				#$log->error("GET again: next $v->{nextOffset} offset $v->{offset},  $v->{streaming}");
				$v->{position} = $v->{nextOffset} = $v->{offset};
				$v->{inBuf} = "";
				$v->{offset} = 0;
				
				$v->{need} = EBML_NEED;
				undef $v->{id};
				
				${*$self}{url} =~ s/&keepalive=yes// if ( !$v->{cue} );
			} 

			if ( $proceed ) {
				$v->{streamBytes} = 0;
				$v->{streaming} = 0 if (!$self->request({ url => ${*$self}{url}, song =>  ${*$self}{song} }));
				$v->{nextOffset} += CHUNK_SIZE;
			}	
			else { $v->{streaming} = 0; }
		}
	}	
	
	#$log->info("loop streamBytes: $v->{streamBytes} inbuf:", length $v->{inBuf}, " outbuf:", length $v->{outBuf});
		
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
			main::DEBUGLOG && $log->debug("timecode: $v->{timecode}");
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
	my $crc = crc32($page);
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
	main::DEBUGLOG && $log->debug("found track: $val (ts: $$time, flags: $flags)");
	
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
	main::DEBUGLOG && $log->debug("size:$$size (tagsize: $total + $len)");
	
	$$in = substr($$in, $len);
	$total += $len;
	
	return $total;
}


# CRC lookup table generated with (direct CRC)
=comment
sub gen_table { 
 $polynomial = 0x04C11DB7 unless (defined $polynomial);
 
 my @crctable;
 
 for (my $i = 0; $i < 256; $i++) {
   my $x = ($i << 24) & 0xffffffff;
   for (my $j = 0; $j < 8; $j++) {
     if ($x & 0x80000000) {
       $x = ($x << 1) ^ $polynomial;
     } else {
       $x = $x << 1;
     }
   }
   push @lookup_table, $x & 0xffffffff;
  }
 } 
=cut
my @crctable = (0x00000000,0x04c11db7,0x09823b6e,0x0d4326d9,0x130476dc,0x17c56b6b,0x1a864db2,0x1e475005,0x2608edb8,0x22c9f00f,0x2f8ad6d6,0x2b4bcb61,0x350c9b64,0x31cd86d3,0x3c8ea00a,0x384fbdbd,0x4c11db70,0x48d0c6c7,0x4593e01e,0x4152fda9,0x5f15adac,0x5bd4b01b,0x569796c2,0x52568b75,0x6a1936c8,0x6ed82b7f,0x639b0da6,0x675a1011,0x791d4014,0x7ddc5da3,0x709f7b7a,0x745e66cd,0x9823b6e0,0x9ce2ab57,0x91a18d8e,0x95609039,0x8b27c03c,0x8fe6dd8b,0x82a5fb52,0x8664e6e5,0xbe2b5b58,0xbaea46ef,0xb7a96036,0xb3687d81,0xad2f2d84,0xa9ee3033,0xa4ad16ea,0xa06c0b5d,0xd4326d90,0xd0f37027,0xddb056fe,0xd9714b49,0xc7361b4c,0xc3f706fb,0xceb42022,0xca753d95,0xf23a8028,0xf6fb9d9f,0xfbb8bb46,0xff79a6f1,0xe13ef6f4,0xe5ffeb43,0xe8bccd9a,0xec7dd02d,0x34867077,0x30476dc0,0x3d044b19,0x39c556ae,0x278206ab,0x23431b1c,0x2e003dc5,0x2ac12072,0x128e9dcf,0x164f8078,0x1b0ca6a1,0x1fcdbb16,0x018aeb13,0x054bf6a4,0x0808d07d,0x0cc9cdca,0x7897ab07,0x7c56b6b0,0x71159069,0x75d48dde,0x6b93dddb,0x6f52c06c,0x6211e6b5,0x66d0fb02,0x5e9f46bf,0x5a5e5b08,0x571d7dd1,0x53dc6066,0x4d9b3063,0x495a2dd4,0x44190b0d,0x40d816ba,0xaca5c697,0xa864db20,0xa527fdf9,0xa1e6e04e,0xbfa1b04b,0xbb60adfc,0xb6238b25,0xb2e29692,0x8aad2b2f,0x8e6c3698,0x832f1041,0x87ee0df6,0x99a95df3,0x9d684044,0x902b669d,0x94ea7b2a,0xe0b41de7,0xe4750050,0xe9362689,0xedf73b3e,0xf3b06b3b,0xf771768c,0xfa325055,0xfef34de2,0xc6bcf05f,0xc27dede8,0xcf3ecb31,0xcbffd686,0xd5b88683,0xd1799b34,0xdc3abded,0xd8fba05a,0x690ce0ee,0x6dcdfd59,0x608edb80,0x644fc637,0x7a089632,0x7ec98b85,0x738aad5c,0x774bb0eb,0x4f040d56,0x4bc510e1,0x46863638,0x42472b8f,0x5c007b8a,0x58c1663d,0x558240e4,0x51435d53,0x251d3b9e,0x21dc2629,0x2c9f00f0,0x285e1d47,0x36194d42,0x32d850f5,0x3f9b762c,0x3b5a6b9b,0x0315d626,0x07d4cb91,0x0a97ed48,0x0e56f0ff,0x1011a0fa,0x14d0bd4d,0x19939b94,0x1d528623,0xf12f560e,0xf5ee4bb9,0xf8ad6d60,0xfc6c70d7,0xe22b20d2,0xe6ea3d65,0xeba91bbc,0xef68060b,0xd727bbb6,0xd3e6a601,0xdea580d8,0xda649d6f,0xc423cd6a,0xc0e2d0dd,0xcda1f604,0xc960ebb3,0xbd3e8d7e,0xb9ff90c9,0xb4bcb610,0xb07daba7,0xae3afba2,0xaafbe615,0xa7b8c0cc,0xa379dd7b,0x9b3660c6,0x9ff77d71,0x92b45ba8,0x9675461f,0x8832161a,0x8cf30bad,0x81b02d74,0x857130c3,0x5d8a9099,0x594b8d2e,0x5408abf7,0x50c9b640,0x4e8ee645,0x4a4ffbf2,0x470cdd2b,0x43cdc09c,0x7b827d21,0x7f436096,0x7200464f,0x76c15bf8,0x68860bfd,0x6c47164a,0x61043093,0x65c52d24,0x119b4be9,0x155a565e,0x18197087,0x1cd86d30,0x029f3d35,0x065e2082,0x0b1d065b,0x0fdc1bec,0x3793a651,0x3352bbe6,0x3e119d3f,0x3ad08088,0x2497d08d,0x2056cd3a,0x2d15ebe3,0x29d4f654,0xc5a92679,0xc1683bce,0xcc2b1d17,0xc8ea00a0,0xd6ad50a5,0xd26c4d12,0xdf2f6bcb,0xdbee767c,0xe3a1cbc1,0xe760d676,0xea23f0af,0xeee2ed18,0xf0a5bd1d,0xf464a0aa,0xf9278673,0xfde69bc4,0x89b8fd09,0x8d79e0be,0x803ac667,0x84fbdbd0,0x9abc8bd5,0x9e7d9662,0x933eb0bb,0x97ffad0c,0xafb010b1,0xab710d06,0xa6322bdf,0xa2f33668,0xbcb4666d,0xb8757bda,0xb5365d03,0xb1f740b4);

sub crc32 {
	my $input = shift;
	my $polynomial = 0x04C11DB7;
	my $crc = 0;
 
	foreach my $x (unpack ('C*', $input)) {
		$crc = (($crc << 8) & 0xffffffff) ^ $crctable[ ($crc >> 24) ^ $x ];
	}

	return $crc;
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
	return unpack('N', substr($_[0], 0, 4))*0x100000000 + unpack('N', substr($_[0], 4, 4)) if ($len == 8);
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
# sub isRepeatingStream { 1 }

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
