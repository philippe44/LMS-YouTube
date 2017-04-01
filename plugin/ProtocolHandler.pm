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
use POSIX qw(ceil :errno_h);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
#use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::YouTube::Signature;
use Plugins::YouTube::WebM;

use constant MAX_INBUF  => 128*1024;
use constant MAX_READ   => 32768;
use constant EBML_NEED  => 12;
use constant CHUNK_SIZE => 8192;	# MUST be less than MAX_READ

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
		$song->can('startOffset') ? $song->startOffset($startTime) : ($song->{startOffset} = $startTime);
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
			'need'        => Plugins::YouTube::WebM::EBML_NEED,  #  minimum size of data to process from Matroska file
			'position'    => 0,       #  byte position in Matroska stream/file
			'streaming'   => 1,       #  flag for streaming, changes to 0 when input socket closes
			'streamBytes' => 0,       #  total bytes received for stream
			'track'		  => undef,	  #  trackinfo
			'cue'		  => $startTime != 0,		  #  cue required flag
			'seqnum'	  => 0,		  #  sequence number
			'offset'      => 0,       #  offset request from stream to be served at next possible opportunity
			'nextOffset'  => Plugins::YouTube::WebM::CHUNK_SIZE,       #  offset to apply to next GET
			'process'	  => 1,		  #  shall sysread data be processed or just forwarded ?
			'startTime'   => $startTime, # not necessary, avoid use in processWebM knows of owner's data
			'metaUpdate'  => 0,		  # need to update metadata like sample rate, size ...
		};
	}
	
	return $self;
}

sub formatOverride { 'ogg' }

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

sub isRemote { 1 }

sub canDirectStream { return 0; }

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
	
	while (!length($v->{'outBuf'}) && $v->{streaming}) {
			
		$bytes = $self->SUPER::sysread($v->{'inBuf'}, MAX_READ, length($v->{'inBuf'}));
		next if !defined $bytes && ($! == EAGAIN || $! == EWOULDBLOCK);
		
		$v->{streaming} = 0 if !defined $bytes;
				
=comment				
		$log->error("processing webM");
		open (my $fh, '>>', "d:/toto/webm");
		binmode $fh;
		print $fh $v->{inBuf};
		close $fh;
=cut		
		
		$log->info("content length: ${*$self}{'contentLength'}") if ( $v->{streamBytes} == 0 );
			
		# process all we have in input buffer
		$v->{streaming} &&= Plugins::YouTube::WebM::processWebM($v) && $bytes;
		$v->{streamBytes} += $bytes;
		
		#$log->info("bytes: $bytes, streamBytes: $v->{streamBytes}");
		
		# GET more data if needed, move to a different offset or force finish if we have started from an offset
		if ( $v->{streamBytes} == ${*$self}{contentLength} ) {
			my $proceed = $v->{cue} || $v->{offset};
			
			# Must test offset first as it is not exclusive with cue but takes precedence
			if ( $v->{offset} ) {
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

	$log->debug('getNextTrack');
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
					$log->debug("raw signature $streamInfo->{'rawsig'}");
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
	
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $var = {	'inBuf'       => shift->content,
						'outBuf'      => '',      
						'id'          => undef,   
						'need'        => Plugins::YouTube::WebM::EBML_NEED,  
						'position'    => 0,       
						'track'		  => undef,	  
						'cue'		  => 0,		  
						'seqnum'	  => 0,		  
						'offset'      => 0,       
				};
	
			Plugins::YouTube::WebM::processWebM($var);
			
			$song->track->secs( $var->{duration} / 1000 ) if $var->{duration};
			
			if ( defined $var->{track} ) {
				${song}->track->bitrate( $var->{track}->{bitrate} );
				${song}->track->samplerate( $var->{track}->{samplerate} );
				${song}->track->samplesize( $var->{track}->{samplesize} );
				${song}->track->channels( $var->{track}->{channels} );
				
				$log->info( "samplerate: $var->{track}->{samplerate}, bitrate: $var->{track}->{bitrate}" );
								
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );	
			}
													
			$cb->();
		},
		
		sub {
			$log->warn("could not get codec info");
			$cb->();
		}
	)->get( $song->pluginData('stream'), 'Range' => 'bytes=0-16384' );
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
					_fulltitle => $fulltitle,
				};
				
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
