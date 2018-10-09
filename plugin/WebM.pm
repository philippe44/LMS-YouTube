package Plugins::YouTube::WebM;

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

use strict;
use Config;

use Slim::Utils::Log;
use Slim::Utils::Cache;

my $cache = Slim::Utils::Cache->new;

use constant HEADER_CHUNK => 8192;

use constant MAX_EBML  => 128*1024;
use constant EBML_NEED  => 12;

use constant WEBM_ERROR => 0;
use constant WEBM_DONE  => 1;
use constant WEBM_MORE  => 2;

use constant ID_HEADER		=> "\x1A\x45\xDF\xA3";
use constant ID_SEGMENT		=> "\x18\x53\x80\x67";
use constant ID_INFO		=> "\x15\x49\xA9\x66";
use constant ID_TIMECODE_SCALE => "\x2A\xD7\xB1";
use constant ID_DURATION    => "\x44\x89";
use constant ID_SEEKHEAD	=> "\x11\x4D\x9B\x74";
use constant ID_SEEK		=> "\x4D\xBB";
use constant ID_SEEK_ID		=> "\x53\xAB";
use constant ID_SEEK_POS	=> "\x53\xAC";
use constant ID_TRACKS 		=> "\x16\x54\xAE\x6B";
use constant ID_TRACK_ENTRY	=> "\xAE";
use constant ID_TRACK_NUM	=> "\xD7";
use constant ID_AUDIO		=> "\xE1";
use constant ID_SAMPLING_FREQ	=> "\xB5";
use constant ID_CHANNELS	=> "\x9F";
use constant ID_BIT_DEPTH	=> "\x62\x64";
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

sub getCues {
	my ($v) = @_;
	
	# just in case caller sends less than EBML_NEED at first call ... stupid but who knows
	return WEBM_MORE if ($v->{need} > length $v->{inBuf});
					
	if ( !defined $v->{id} ) {
		my $id;
		my $size;
		
		getEBML(\$v->{inBuf}, \$id, \$size);
					
		if ($id ne ID_CUES) {
			$log->error("wrong cues offset" );
			return WEBM_ERROR;
		}	
						
		$v->{id} = $id;
		$v->{need} = $size;
				
		if ($size > MAX_EBML) {
			$log->error("EBML too large: $size");
			return WEBM_ERROR;
		}
	}	
	
	if ( $v->{need} <= length $v->{inBuf} ) {
		$v->{outBuf} = substr( $v->{inBuf}, 0, $v->{need} );
		return WEBM_DONE;
	}
	
	return WEBM_MORE;
}


sub getHeaders {
	my ($v, $props) = @_;
	
	# process all we can
	while ($v->{need} <= length $v->{inBuf}) {
		my $id;
		my $size;
			
		# first need to acquired an ID	
		if ( !defined $v->{id} ) {
			$v->{position} += getEBML(\$v->{inBuf}, \$id, \$size);
					
			if ($id eq ID_CLUSTER) {
				$log->error("no info found");
				return WEBM_ERROR;
			} elsif ($id eq ID_SEGMENT) {
				$props->{segment_offset} = $v->{position};
				next;
			} elsif ($id eq ID_TRACKS) {
				next;
			}
			
			$v->{id} = $id;
			$v->{need} = $size;
				
			if ($size > MAX_EBML) {
				$log->error("EBML too large: $size");
				return WEBM_ERROR;
			}
					
			next;
		}
		
		$id = $v->{id};
		$size = $v->{need};
		
		# consume branches lower than L1 (item by item)
		if ($id eq ID_SEEKHEAD) {
			my $seektable = substr $v->{inBuf}, 0, $size;
			$props->{offset}->{cues} = getSeekOffset($seektable, ID_CUES) + $props->{segment_offset};
			$props->{offset}->{tracks} = getSeekOffset($seektable, ID_TRACKS) + $props->{segment_offset};
			$log->debug("offset: cues=$props->{offset}->{cues}, tracks=$props->{offset}->{tracks}");
		} elsif ($id eq ID_INFO) {
			$props->{timecode_scale} = getInfo(substr($v->{inBuf}, 0, $size), ID_TIMECODE_SCALE, "u") || 1000000;
			$log->debug("track timecode scale: $props->{timecode_scale}");
			$props->{duration} = getInfo(substr($v->{inBuf}, 0, $size), ID_DURATION, "f") / (1000000 / $props->{timecode_scale});
			$log->info("track duration: $props->{duration}");
		} elsif	($id eq ID_TRACK_ENTRY) {
			$props->{track} = getTrackInfo(substr $v->{inBuf}, 0, $size);
			$props->{offset}->{clusters} = $v->{position} + $size;
			$log->debug("offset: clusters=$props->{offset}->{clusters}");
		} 	
				
		$v->{inBuf} = substr($v->{inBuf}, $size);
		$v->{need} = EBML_NEED;
		$v->{position} += $size;
		undef $v->{id};
		
		return WEBM_DONE if defined $props->{offset} && defined $props->{duration} && defined $props->{track};
	}	
	
	return WEBM_MORE;
}


sub getAudio {
	my ($v, $props) = @_;
	
	$v->{need}		//= EBML_NEED;		# number of bytes in buffr to allow processing
	$v->{position}	//= 0;      		# number of bytes processed from buffer since 1st call
		
	if ( !defined $v->{seqnum} ) {
		$v->{seqnum} = 0;
		$v->{outBuf} = buildOggPage( [$props->{track}->{codec}->{header}], 0, 0x02, $v->{seqnum}++ );
		$v->{outBuf} .= buildOggPage( [$props->{track}->{codec}->{setup}, $props->{track}->{codec}->{comment}], 0, 0x00, $v->{seqnum}++ );
		$log->debug("starting new audio parsing");
	}
	
	# process all we can
	while ($v->{need} <= length $v->{inBuf}) {
		my $id;
		my $size;
			
		# first need to acquired an ID	
		if ( !defined $v->{id} ) {
			$v->{position} += getEBML(\$v->{inBuf}, \$id, \$size);
						
			# skip id that are not CLUSTER *except* the SEGMENT !
			$log->info("cluster of $size byte (last audio $v->{timecode} ms)") if ($id eq ID_CLUSTER);
			next if $id eq ID_CLUSTER || $id eq ID_SEGMENT;
			
			$v->{need} = $size;	
			$v->{id} = $id;
										
			if ($size > MAX_EBML) {
				$log->error("EBML too large: $size");
				return WEBM_ERROR;
			}
					
			next;
		}
		
		$id = $v->{id};
		$size = $v->{need};
						
		# handle sub-ID's we care		
		if ($id eq ID_TIMECODE) {
			$v->{timecode} = decode_u(substr($v->{inBuf}, 0, $size), $size);
			$log->debug("timecode: $v->{timecode}");
		} elsif ($id eq ID_BLOCK || $id eq ID_BLOCK_SIMPLE) {
			my $time;
			my $out = extractVorbis(\$v->{inBuf}, $props->{track}->{tracknum}, $size, \$time);
									
			if (defined $out) { 
				my $pos = ($v->{timecode} + $time) * $props->{track}->{samplerate} / ($props->{timecode_scale} / 1000);
				$v->{outBuf} .= buildOggPage([$out], $pos, 0x00, $v->{seqnum}++);
			}	
		}	
						
		$v->{inBuf} = substr($v->{inBuf}, $size);
		$v->{need} = EBML_NEED;
		$v->{position} += $size;
		undef $v->{id};
								
	}	
	
	return WEBM_MORE;
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
	my ($packets, $granule, $flags, $seq) = @_;
	my $count = 0;
	my $data = "";
	
	# 0-3:pattern 4:vers 5:flags 6-13:granule 14-17:serial num 18-21:seqno 22-25:CRC 26:Nseq 27...:segtable
	my $page = ("OggS" . "\x00" . pack("C", $flags) . 
				($Config{ivsize} == 8 ? pack("Q", $granule) : (pack("V", int ($granule)) . pack("V", int ($granule/4294967296)))) . 
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
Audio 				3 [E1]					m
SamplingFrequency 	4 [B5] 					f
Channels			4 [9F] 					u
BitDepth			4 [62][64]				u
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
		} elsif ($id eq ID_AUDIO) {
			my $data = substr($s, 0, $size);
			my ($id, $size);
			while (length $data) {
				getEBML(\$data, \$id, \$size);
				$info->{samplerate} = decode_f(substr($data, 0, $size), $size) if ($id eq ID_SAMPLING_FREQ);
				$info->{channels} = decode_u(substr($data, 0, $size), $size) if ($id eq ID_CHANNELS);
				$info->{samplesize} = decode_u(substr($data, 0, $size), $size) if ($id eq ID_BIT_DEPTH);
				$data = substr $data, $size;
			}
		}
		$s = substr $s, $size;
	} 
	
	# codec private data shall only be used once we have found codec
	my $count = decode_u8(substr $private, 0, 1) + 1;
	my $hdr_size = decode_u8(substr $private, 1, 1);
	my $set_size = decode_u8(substr $private, 2, 1);
	$log->debug ("private count $count, hdr: $hdr_size, setup: $set_size, total: ". length($private));
									
	# the explanation for the packet length & offsets of codec private data are found here
	# https://matroska.org/technical/specs/codecid/index.html 
	$info->{codec}->{header} = substr $private, 3, $hdr_size;
	$info->{codec}->{setup} = substr $private, 3 + $hdr_size, $set_size;
	$info->{codec}->{comment} = substr $private, 3 + $hdr_size + $set_size, length($private) - 3 - $set_size - $hdr_size;
	
	# header contains more accurate information
	$info->{channels} = decode_u8(substr($info->{codec}->{header}, 11, 1));
	$info->{samplerate} = unpack('V', substr($info->{codec}->{header}, 12, 4));
	$info->{bitrate} = unpack('V', substr($info->{codec}->{header}, 20, 4));
	$info->{samplesize} = 16 unless ($info->{samplesize} == 8);
			
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
		# arbitrary, but at least won't get stuck in the an infinite loop and will not go beyond available data
		$len = EBML_NEED; 	
		$$in = substr($$in, $len);
		return $len;
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
sub decode_u64 { 
	return unpack('Q>', substr($_[0], 0, 8)) if $Config{ivsize} == 8;
	$log->error("can't unpack 64 bits integer, using 32 bits LSB");
	return unpack('N', substr($_[0], 4, 4));
}
sub decode_u { 
	my ($s, $len) = @_;
	return unpack('C', $_[0]) if ($len == 1);
	return unpack('n', $_[0]) if ($len == 2);
	return unpack('N', ("\0" . $_[0]) ) if ($len == 3);
	return unpack('N', $_[0]) if ($len == 4);
	if ($len == 8) {
		return unpack('Q>', substr($_[0], 0, 8)) if $Config{ivsize} == 8;
		$log->error("can't unpack 64 bits integer, using 32 bits LSB");
		return unpack('N', substr($_[0], 4, 4));
	} 
	return undef;
}
sub decode_f { 
	my ($s, $len) = @_;
	return unpack('f>', $_[0]) if ($len == 4);
	return unpack('d>', $_[0]) if ($len == 8);
	return undef;
}


sub getStartOffset {
	my ($url, $startTime, $props, $cb) = @_;
	my $process;
	my $var = {	'inBuf'       => '',
				'id'          => undef,   
				'need'        => EBML_NEED,  
				'offset'      => $props->{offset}->{cues},       
		};
	
	$process = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
		
			sub {
				my $content = shift->content;
								
				$var->{'inBuf'} .= $content;
				my $res = getCues($var);
				
				if ( $res eq WEBM_MORE ) {
					return $cb->( $props->{offset}->{clusters} ) if length($content) < HEADER_CHUNK; 
					
					main::DEBUGLOG && $log->is_debug && $log->debug("paging: $var->{offset}");
					$var->{offset} += length $content;
					$process->();
				} elsif ( $res eq WEBM_DONE ) {	
					my $offset = getCueOffset($var->{outBuf}, $startTime*($props->{timecode_scale}/1000000)*1000) + $props->{segment_offset};
					$cb->($offset);
				} elsif ( $res eq WEBM_ERROR ) {
					$log->warn( "could not find start offset" );
					$cb->( $props->{offset}->{clusters} );
				}		
			},
		
			sub {
				$log->warn( "could not find start offset" );
				$cb->( $props->{offset}->{clusters} );
			}
		)->get( $url, 'Range' => "bytes=$var->{'offset'}-" . ($var->{'offset'} + HEADER_CHUNK - 1) );
	 };	
	
	$process->();
}

sub getProperties {
	my ($song, $props, $cb) = @_;
	my $client = $song->master();
	my $process;
	my $var = {	'inBuf'       => '',
				'id'          => undef,   
				'need'        => EBML_NEED,  
				'offset'      => 0,       
		};
	
	$process = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
		
			sub {
				my $content = shift->content;
								
				$var->{'inBuf'} .= $content;
				my $res = getHeaders($var, $props);
				
				if ( $res eq WEBM_MORE ) {
					return $cb->() if length($content) < HEADER_CHUNK; 
					
					main::DEBUGLOG && $log->is_debug && $log->debug("paging: $var->{offset}");
					$var->{offset} += length $content;
					$process->();
				} elsif ( $res eq WEBM_DONE ) {	
					$song->track->secs( $props->{'duration'} / 1000 ) if $props->{'duration'};
					$song->track->bitrate( $props->{'track'}->{'bitrate'} );
					$song->track->samplerate( $props->{'track'}->{'samplerate'} );
					$song->track->samplesize( $props->{'track'}->{'samplesize'} );
					$song->track->channels( $props->{'track'}->{'channels'} );
					
					my $id = Plugins::YouTube::ProtocolHandler->getId($song->track()->url);
					if (my $meta = $cache->get("yt:meta-$id")) {
						$meta->{type} = "YouTube (ogg\@$props->{'track'}->{'samplerate'}Hz)";
						$cache->set("yt:meta-$id", $meta);
					}
				
					main::INFOLOG && $log->is_info && $log->info( "samplerate: $props->{'track'}->{'samplerate'}, bitrate: $props->{'track'}->{'bitrate'}" );
											
					$client->currentPlaylistUpdateTime( Time::HiRes::time() );
					Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );	
									
					$cb->();
				} elsif ( $res eq WEBM_ERROR ) {
					$log->error( "could not get webm headers" );
					$cb->();
				}		
			},
		
			sub {
				$log->warn("could not get codec info");
				$cb->();
			}
		)->get( $song->pluginData('baseURL'), 'Range' => "bytes=$var->{'offset'}-" . ($var->{'offset'} + HEADER_CHUNK - 1) );
	 };	
	
	$process->();
}


1;
