package Plugins::YouTube::M4a;

# (c) 2018, philippe_44@outlook.com
# m4a parser and DASH from baltontwo@eircom.net
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
use bytes;

use base qw(Slim::Utils::Accessor);

use Slim::Utils::Log;
use Slim::Utils::Cache;

my $cache = Slim::Utils::Cache->new;
my $log   = logger('plugin.youtube');

use Data::Dumper;

use constant MAX_INBUF  => 128*1024;
use constant MAX_OUTBUF => 4096;
use constant MAX_READ   => 32768;

use constant ATOM_NEED	=> 8;

# streaming states
use constant ATOM     => 1;
use constant PARSING  => 2;
use constant DATA	  => 3;

{
	__PACKAGE__->mk_accessor('rw', qw(bitrate samplerate channels url));
	__PACKAGE__->mk_accessor('rw', qw(_mp4a _context));
}

sub new {
	my ($class, $url) = @_;
	my $self = $class->SUPER::new;

	# _context is to be flushed/initialized each time the getAudio is restarted
	# but _mp4a is to be used for the duration of the objects, i.e. when seeking	
	$self->init_accessor(
		url => $url,
		_context => {},
		_mp4a => {},
	);	
	
	return bless $self, $class;
}	

sub flush {
	$_[0]->_context( { } );
}	

sub addBytes {
	my ($self, $data) = @_;
	$self->_context->{'inBuf'} .= ref $data ? $$data : $data;
}	

sub bufferLength {
	return length $_[0]->_context->{'inBuf'};
}	

sub getStartOffset {
	my ($self, $url, $startTime, $cb) = @_;
	my $index = 0;
	my $time = 0;
	
	return $cb->(0) unless $startTime;
	
	my $http = Slim::Networking::Async::HTTP->new;
	my $args = { startTime => $startTime };
		
	$http->send_request( {
		request     => HTTP::Request->new( GET => $url ),
		
		onStream  	=> sub {
			my ($http, $dataref) = @_;
			
			if (my $atom = parseAtoms('sidx', $dataref, $args)) {
				my $offset = $args->{offset} || 0;
				$startTime -= $atom->{time};

				foreach my $item (@{$atom->{indexes}}) {
					last if ($args->{startTime} -= $item->{duration} / $atom->{timescale}) <= 0;
					$offset += $item->{size};
				}

				main::INFOLOG && $log->is_info && $log->info("using sidx for offset");
				$cb->($offset);
				return 0;
			} elsif ($args->{offset} < 128*1024) {
				return 1;
			} else {	
				$log->warn( "could not find get offset within $args->{offset} bytes" );
				$cb->();
				return 0;
			}	
		},
		
		onError     => sub {
			my ($self, $error) = @_;
			$log->warn( "could not find start offset $error " );
			$cb->(0);
		},
	} );

}	

sub initialize {
	my ($self, $cb, $ecb, $url) = @_;
	my $http = Slim::Networking::Async::HTTP->new;
	my $args = {};
	
	# we might have received an initialize url
	$url ||= $self->url;
	
	$http->send_request( {
		request     => HTTP::Request->new( GET => $url ),
		onStream  	=> sub {
			my ($http, $dataref) = @_;
						
			if (my $atom = parseAtoms('moov', $dataref, $args)) {
				$self->_mp4a($atom->{'trak'}->{'mdia'}->{'minf'}->{'stbl'}->{'stsd'}->{'entries'}->{'mp4a'});	
				$self->bitrate($self->_mp4a->{'esds'}->{'avgbitrate'});
				$self->samplerate($self->_mp4a->{'samplerate'});
				$self->channels($self->_mp4a->{'channelcount'}); 
	
				main::INFOLOG && $log->is_info && $log->info("found moov (in $args->{offset} bytes) and set properties abr: ", $self->bitrate, 
															 " sr:",$self->samplerate, " ch:", $self->channels); 															 
				
				$cb->();
				return 0;
			} elsif ($args->{offset} < 128*1024) {
				return 1;
			} else {	
				$log->warn( "could not find get properties within $args->{offset} bytes" );
				$ecb->();
				return 0;
			}	
		},
		onError     => sub {
			my ($self, $error) = @_;
			$log->warn( "could not get properties $error" );
			$ecb->();
		},
	} );
}	

sub parseAtoms {
	my ( $atom, $dataref, $context ) = @_;
		
	if (!defined $context->{offset}) {	
		$context->{offset} = 0;	
		$context->{_parser} = {	'inBuf'       => '',
							'state'       => ATOM,   
							'need'        => ATOM_NEED,  
							'offset'      => 0,       
		};
	}	
		
	my $v = $context->{_parser};
	$v->{'inBuf'} .= $$dataref;
	
	while ($v->{need} <= length $v->{inBuf}) {
	
		if ($v->{state} == ATOM) {
			my ($atom, $size) = get_next_atom($v->{inBuf});
					
			$v->{need} = $size - 8;
			$v->{atom} = $atom;
			$v->{state} = PARSING;
			substr($v->{inBuf}, 0, 8, '');
			$context->{offset} += $size;
		}	

		return undef if $v->{need} > length $v->{inBuf};
		
		# enough data to process box and all included sub-boxes
		$v->{$v->{atom}} = process_atom($v->{atom}, $v->{need}, substr($v->{inBuf}, 0, $v->{need}));
			
		substr($v->{inBuf}, 0, $v->{need}, '');
		$v->{state} = ATOM;
		$v->{need} = ATOM_NEED;

		# have we acquired the desired atom 
		return $v->{$atom} if $v->{$atom};
	}	
	
	return undef;
}

sub getAudio {
	my ($self, $outBuf) = @_;
	my $v = $self->_context;
	
	$v->{state} //= ATOM;
	$v->{need}	//= ATOM_NEED;
	
	# process all we can ... might be over the MAX_OUTBUF
	while ($v->{need} <= length $v->{'inBuf'}) {
								
		if ($v->{state} == ATOM) {
			my ($atom, $size) = get_next_atom($v->{'inBuf'});
					
			$v->{need} = $size - 8;
			$v->{atom} = $atom;
			$v->{state} = PARSING;
			substr($v->{'inBuf'}, 0, 8, '');
		}	

		return 1 if $v->{need} > length $v->{'inBuf'};
	
		# process the atom (just what we need)
		$v->{$v->{atom}} = process_atom($v->{atom}, $v->{need}, substr($v->{'inBuf'}, 0, $v->{need}));
			
		substr($v->{'inBuf'}, 0, $v->{need}, '');
		$v->{state} = ATOM;
		$v->{need} = ATOM_NEED;
		
		if ($v->{mdat}) {
			# mp4a data can come from segment (MPD) or be unique for a file (regular stream)
			my $mp4a = $v->{'moov'}->{'trak'}->{'mdia'}->{'minf'}->{'stbl'}->{'stsd'}->{'entries'}->{'mp4a'} || $self->_mp4a;	
			$$outBuf .= convertDashSegtoADTS($mp4a->{'esds'}, $v->{mdat}->{data}, $v->{'moof'}->{'traf'});
			main::DEBUGLOG && $log->is_debug && $log->debug("extracted ", length $v->{mdat}->{data}, " bytes, out ", length $$outBuf);
			$v->{mdat} = undef;
		}	
	}	
	
	return 1;
}

my  %atom_handler = (
	'moov' => sub { process_container('moov', @_) },
	'trak' => sub { process_container('trak', @_) },
	'edts' => sub { process_container('edts', @_) },
	'mdia' => sub { process_container('mdia', @_) },
	'minf' => sub { process_container('minf', @_) },
	'stbl' => sub { process_container('stbl', @_) },
	'stsd' => \&process_stsd_atom,
	'sidx' => \&process_sidx_atom,
	'mp4a' => \&process_mp4a_atom,
	'esds' => \&process_esds_atom,
	'mvex' => sub { process_container('mvex', @_) },
	'moof' => sub { process_container('moof', @_) },
	'traf' => sub { process_container('traf', @_) },
	'tfhd' => \&process_tfhd_atom,
	'trun' => \&process_trun_atom,
	'mfra' => sub { process_container('mfra', @_) },
	'skip' => sub { process_container('skip', @_) },
	'mdat' => \&process_mdat_atom,
	);	
	
sub process_atom {
    my ($type, $size, $data) = @_;
	my $result;
	
	$log->debug("processing atom $type of $size bytes");
	$result = $atom_handler{$type}($size, $data) if ($atom_handler{$type});
			
	return $result;

}
    
sub get_next_atom {
    my $data = shift;
	
	my $size = decode_u32($data);
    my $type = substr($data, 4, 4);

    if ($size == 0) {
		$log->error("Atom size zero $type");
    } elsif ($size == 1) {
		$log->error("Atom size 1 - extralarge - not with isobff") ;
    }
    
    return ($type, $size);
}  

sub process_container {
    my ($type, $size, $data) = @_;
    my %result ;
    
	while ($size){
		my ($sub_type, $sub_size) = get_next_atom($data);
		   
		$result{$sub_type} = process_atom($sub_type, $sub_size - 8, substr($data, 8, $sub_size - 8));
		substr($data, 0, $sub_size, '');
		$size -= $sub_size;
	}
	 
    return \%result ;
}

sub process_tfhd_atom {
	my ($size, $data) = @_;
    my %result;
    
    $result{'version'}   = decode_u8($data);
    $result{'tf_flags'}  = decode_u24(substr($data,  1, 3));
	$result{'track_ID'}  = decode_u32(substr($data,  4, 4));
	
	my $base = 8;
	
	if ( $result{'tf_flags'} & 0x1) {
		$base += 8;
	}
	if ( $result{'tf_flags'} & 0x2) {
		$result{'sample_description_index'} = decode_u32(substr($data, $base, 4));
		$base += 4;
	}	
	if ( $result{'tf_flags'} & 0x8) {
		$result{'default_sample_duration'} = decode_u32(substr($data, $base, 4));
		$base += 4;
	}	
	if ( $result{'tf_flags'} & 0x10) {
		$result{'default_sample_size'} = decode_u32(substr($data, $base, 4));
		$base += 4;
	}	
	if ( $result{'tf_flags'} & 0x20) {
		$result{'default_sample_flags'} = decode_u32(substr($data, $base, 4));
		$base += 4;
	}	
	
    return  \%result ;

}

sub process_trun_atom {
    my ($size, $data) = @_;
    my %result;
    my $base = 0;
    
    $result{'version'}      = decode_u8($data);
    $result{'tr_flags'}     = decode_u24(substr($data, 1, 3));
	$result{'sample_count'} = decode_u32(substr($data, 4, 4));
	
	if ( $result{'tr_flags'} & 0x1) {
		$result{'data_offset'} = decode_u32(substr($data,  8, 4)) ;
		$base += 4;
	}
	
	if ( $result{'tr_flags'} & 0x4) {
		$result{'first_sample_flags'} = decode_u32(substr($data, 8+$base, 4)) ;
		$base += 4;
	}
	
	my @samples;
	
	for (my $i = 0; $i < $result{'sample_count'} ; $i++) {
		my %sample;
		if ( $result{'tr_flags'} & 0x100) {
			$sample{'sample_duration'} = decode_u32(substr($data, 8+$base, 4)); 
			$base += 4;
		}
		if ( $result{'tr_flags'} & 0x200) {
			$sample{'sample_size'} = decode_u32(substr($data, 8+$base, 4));
			$base += 4;
		}
		if ( $result{'tr_flags'} & 0x400) {
			$sample{'sample_flags'} = decode_u32(substr($data, 8+$base, 4));
			$base += 4;
		}
		
		if ( $result{'tr_flags'} & 0x800) {
			if ($result{'version'} ==1) {
				$sample{'sample_composition_time_offset'} = decode_u32(substr($data, 8+$base, 4));
			} else {
				$sample{'sample_composition_time_offset'} = decode_u32(substr($data, 8+$base, 4));
			}
		}
		push @samples, \%sample ;
	}
	
	$result{'samples'} = \@samples;
    return  \%result ;
}

sub process_stsd_atom {
	my ($size, $data) = @_;
	my $offset = 0;
    my %result;    
    
	$result{'version'}     = decode_u8($data);
    $result{'flags'}       = decode_u24(substr($data, 1, 3));
	$result{'entry_count'} = decode_u32(substr($data, 4, 4));
	$result{'entries'} = {};
	
	for (my $i = 0 ; $i < $result{'entry_count'} ; $i++) {
		# Assumed entry is Audio
		# FIXME : not sure iteration is correct
		my ($sub_type, $sub_size) = get_next_atom(substr($data, 8+$offset));
		$result{'entries'}{$sub_type} = process_atom($sub_type, $sub_size - 8, substr($data, 16+$offset));
		$offset += $sub_size;
	}
	
    return  \%result ;
}

sub process_sidx_atom {
	my ($size, $data) = @_;
	my $offset = 24;
    my %result;    
    
	$result{'version'}     = decode_u32($data, 0, 4);
	$result{'reference_id'} = decode_u32(substr($data, 4, 4));
	$result{'timescale'} = decode_u32(substr($data, 8, 4));

	if ($result{'version'}) {
		$result{'time'} = decode_u64(substr($data, 12, 8));
		$result{'offset'} = decode_u64(substr($data, 20, 8));
		$offset += 8;
	} else {
		$result{'time'} = decode_u32(substr($data, 12, 4));
		$result{'offset'} = decode_u32(substr($data, 16, 4));
	}	
	
	# big endian order ...
	$result{'reserved'} = decode_u16(substr($data, 20, 2));
	$result{'reference_count'} = decode_u16(substr($data, 22, 2));
	$result{'indexes'} = [ ];

	for (my $i = 0 ; $i < $result{'reference_count'} ; $i++) {
		my $size = decode_u32(substr($data, $offset, 4)) & 0x7fffffff;
		my $duration = decode_u32(substr($data, 4+$offset, 4));
		my $SAP = decode_u32(substr($data, 8+$offset, 4));
		push @{$result{'indexes'}}, { size => $size, duration => $duration, SAP => $SAP };
		$offset += 12;
	}
	
    return  \%result ;
}

sub process_mp4a_atom {
	my ($size, $data) = @_;
    my %result;    
    
	$result{'reserved'}  			 =  substr($data, 0, 6) ;
	$result{'data_reference_index'}  =  decode_u16(substr($data, 6, 2));
	$result{'reserved2'}             = [ decode_u32(substr($data,  8, 4)),
		                                 decode_u32(substr($data, 12, 4)) ];
	$result{'channelcount'}          =  decode_u16(substr($data, 16, 2));
	$result{'samplesize'}            =  decode_u16(substr($data, 18, 2));
	$result{'predefined'}            =  decode_u16(substr($data, 20, 2));
	$result{'reserved3'}             =  decode_u16(substr($data, 22, 2));
	# FIXME : buffersizedb seems to be little endian or some other format
	# samplerate seems to be big-endian, but 16 upper bits 
	$result{'samplerate'}            =  decode_u32(substr($data, 24, 4)) >> 16;
	if ($size > 28) {
		# Assumed entry is Audio
		my ($sub_type, $sub_size) = get_next_atom(substr($data, 28));
		$result{$sub_type} = process_atom($sub_type, $sub_size - 8, substr($data, 36));
	}
	
	return  \%result ;
}

sub process_esds_atom {
	my ($size, $data) = @_;
    my %result;    
    my $tag;
    my $tag_size;
    my $dummy;
       
    $result{'version'} = decode_u8($data);
    $result{'flags'}   = decode_u24(substr($data, 1, 3));
    
    $tag = decode_u8(substr($data, 4, 1));
    if ($tag != 0x03) {
		$log->error("Unexpected tag value $tag expected 03\n");
		return {"bad tag $tag not 03"};
	}
	
    $tag_size = decode_u8(substr($data, 5, 1));
    my $es_id = decode_u32(substr($data, 6, 2));
    $result{'esflags'} = decode_u8(substr($data,  8, 1));
    
	$tag = decode_u8(substr($data, 9, 1));
    if ($tag != 0x04) {
		$log->error("Unexpected tag value $tag expected 04\n");
		return {"bad tag $tag not 04"};
	}
	
    $tag_size = decode_u8(substr($data, 10, 1));
    $result{'objectTypeId'} = decode_u8(substr($data, 11, 1));
	# FIXME : buffersizedb seems to be little endian
    $result{'buffersizedb'} = decode_u32(substr($data, 12, 4));
    $result{'maxbitrate'}   = decode_u32(substr($data, 16, 4));
    $result{'avgbitrate'}   = decode_u32(substr($data, 20, 4));

    $tag = decode_u8(substr($data, 24, 1));
    if ($tag != 0x05) {
		$log->error("Unexpected tag value $tag expected 05\n");
		return {"bad tag $tag not 05"};
	}
	
    $tag_size = decode_u8(substr($data, 25, 1));
	    
	my $audiospecificconfig = decode_u32(substr($data, 26, 4));
    $result{'AudioObjectType'} =  $audiospecificconfig >> 27;
    $result{'FreqIndex'}       = ($audiospecificconfig >> 23)  & 0x0F; 
    $result{'channelConfig'}   = ($audiospecificconfig >> 19)  & 0x0F; 
    
	my $offset = $tag_size -4;
    $tag = decode_u8(substr($data,  30+$offset, 1));
    if ($tag != 0x06) {
		$log->error("Unexpected tag value $tag expected 06\n");
		$log->error(sprintf("Dumpesds atom body length %d  body %0*v2X\n", $size,"  ",  $data));
		return {"bad tag $tag not 06"};
	}
    
	$tag_size = decode_u8(substr($data, 31+$offset, 1));
    $result{'version'} = decode_u8(substr($data,  0, 1));
	
	main::DEBUGLOG && $log->is_debug && $log->debug("esds result ". Dumper(\%result));

    return  \%result ;
}

sub process_mdat_atom {
    my ($size, $data) = @_;
    
    return { 'data' => $data };
}

sub mp4esdsToADTSHeader {	
	my ($mp4esds, $framelength) = @_;
# AAAAAAAA AAAABCCD EEFFFFGH HHIJKLMM MMMMMMMM MMMOOOOO OOOOOOPP 
#
# Header consists of 7 bytes without CRC.
#
# Letter	Length (bits)	Description
# A	12	syncword 0xFFF, all bits must be 1
# B	1	MPEG Version: 0 for MPEG-4, 1 for MPEG-2
# C	2	Layer: always 0
# D	1	set to 1 as there is no CRC 
# E	2	profile, the MPEG-4 Audio Object Type minus 1
# F	4	MPEG-4 Sampling Frequency Index (15 is forbidden)
# G	1	private bit, guaranteed never to be used by MPEG, set to 0 when encoding, ignore when decoding
# H	3	MPEG-4 Channel Configuration (in the case of 0, the channel configuration is sent via an inband PCE)
# I	1	originality, set to 0 when encoding, ignore when decoding
# J	1	home, set to 0 when encoding, ignore when decoding
# K	1	copyrighted id bit, the next bit of a centrally registered copyright identifier, set to 0 when encoding, ignore when decoding
# L	1	copyright id start, signals that this frame's copyright id bit is the first bit of the copyright id, set to 0 when encoding, ignore when decoding
# M	13	frame length, this value must include 7 bytes of header 
# O	11	Buffer fullness
# P	2	Number of AAC frames (RDBs) in ADTS frame minus 1, for maximum compatibility always use 1 AAC frame per ADTS frame

	my $profile         =  $mp4esds->{'AudioObjectType'}; 
	
	$log->error("Unusual AudioObjectType $profile" ) if $profile != 5 && $profile != 2;
	
	$profile = 2 if ($profile == 5); # Fix because Touch and Radio cannot handle ADTS header of AAC Main.
	
    my $frequency_index =  $mp4esds->{'FreqIndex'};       
    my $channel_config  =  $mp4esds->{'channelConfig'};   
	my $finallength     = $framelength + 7;       
	my @ADTSHeader      = (0xFF,0xF1,0,0,0,0,0xFC);
	
    $ADTSHeader[2] = (((($profile & 0x3) - 1)  << 6)   + ($frequency_index << 2) + ($channel_config >> 2));
    $ADTSHeader[3] = ((($channel_config & 0x3) << 6)   + ($finallength >> 11));
    $ADTSHeader[4] = ( ($finallength & 0x7ff) >> 3);
    $ADTSHeader[5] = ((($finallength & 7) << 5) + 0x1f) ;
	my $adts = pack("CCCCCCC",@ADTSHeader);

	return $adts;
}	

sub convertDashSegtoADTS{
	my ($mp4esds, $dashsegment, $traf) = @_;
	my $segpos = 0;
	my $sample_count = $traf->{'trun'}->{'sample_count'};
	my $adtssegment ='';
	
	foreach my $sample (@{$traf->{'trun'}->{'samples'}}) {
		my $sample_size = $sample->{'sample_size'} || $traf->{'tfhd'}->{'default_sample_size'};
		$adtssegment .= mp4esdsToADTSHeader($mp4esds, $sample_size);
		$adtssegment .= substr($dashsegment,$segpos, $sample_size);
		$segpos += $sample_size;
	}
	
	return $adtssegment;
}

sub decode_u8  { unpack('C', $_[0]) }
sub decode_u16 { unpack('n', $_[0]) }
sub decode_u24 { unpack('N', ("\0" . $_[0]) ) }
sub decode_u32 { unpack('N', $_[0]) }
sub decode_u64 { 
	return unpack('Q>', substr($_[0], 0, 8)) if $Config{ivsize} == 8;
	$log->warn("can't unpack 64 bits integer, using 32 bits LSB");
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
		$log->warn("can't unpack 64 bits integer, using 32 bits LSB");
		return unpack('N', substr($_[0], 4, 4));
	} 
	return undef;
}
sub decode_f { 
	my ($s, $len) = @_;
	return unpack('f>', $_[0]) if ($len == 4);
	return unpack('d>', $_[0]) if ($len == 8);
	return undef;
}	1;
