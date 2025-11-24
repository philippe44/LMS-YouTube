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
use feature 'state';

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
use File::Temp qw (tmpnam);
use FindBin qw($Bin);
use XML::Simple;
use POSIX qw(strftime);
use AnyEvent::Util;

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;

use Plugins::YouTube::WebM;
use Plugins::YouTube::M4a;
use Plugins::YouTube::MPEGTS;
use Plugins::YouTube::Utils;
use Plugins::YouTube::HTTP;

use constant MIN_OUT	=> 8192;
use constant DATA_CHUNK => 128*1024;
use constant PAGE_URL_REGEXP => qr{^https?://(?:(?:www|m|music)\.youtube\.com/(?:watch\?|playlist\?|channel/)|youtu\.be/)}i;

=comment
FIXME: find a video that use dash
There is a voluntary 'confusion' between codecs and streaming formats
(regular http or dash). As we only support ogg/opus with webm and aac
with dash and hls with mpeg-ts, this is not a problem at this point,
although not very elegant.
This only works because it seems that YT, when using webm and dash (171)
does not build a mpd file but instead uses regular webm. It might be due
to http://wiki.webmproject.org/adaptive-streaming/webm-dash-specification
but I'm not sure at that point. Anyway, the dash webm format used in codec
171, 251, 250 and 249, probably because there is a single stream, does not
need a different handling than normal webm
=cut

my @audioId = (
	{ id => 251, codec => 'ops', rate => 160_000 }, { id => 250, codec => 'ops', rate => 70_000 }, { id => 249, codec => 'ops', rate => 50_000 },
	{ id => 171, codec => 'ogg', rate => 128_000 },
	{ id => 141, codec => 'aac', rate => 256_000 }, { id => 140, codec => 'aac', rate => 128_000 }, { id => 139, codec => 'aac', rate => 48_000 },
);

my @videoId = (
	{ id => 95, codec => 'aac', prio => 1 }, { id => 94, codec => 'aac', prio => 2 }, { id => 93, codec => 'aac', prio => 3 }, { id => 92, codec => 'aac', prio => 4 },
);

my $log   = logger('plugin.youtube');
my $prefs = preferences('plugin.youtube');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerHandler('youtube', __PACKAGE__);
Slim::Player::ProtocolHandlers->registerURLHandler(PAGE_URL_REGEXP, __PACKAGE__)
    if Slim::Player::ProtocolHandlers->can('registerURLHandler');

sub flushCache { $cache->cleanup(); }

sub canDoAction {
    my ( $class, $client, $url, $action ) = @_;
	my $config = $client->playingSong()->pluginData('config');

	main::INFOLOG && $log->is_info && $log->info("action=$action");

	if ($config->{source} =~ /dash/) {
		# if restart, restart from beginning (stop being live edge)
		my $mpd = $client->playingSong()->pluginData('stash');
		$mpd->{liveOffset} = 0 if  $action eq 'rew' && $client->isPlaying(1);
	}

	return 1;
}

sub new {
	my $class = shift;
	my $args  = shift;
	my $song  = $args->{'song'};
	my $config = $song->pluginData('config');
	my $stash = $song->pluginData('stash') || {};

	my $self = $class->SUPER::new;
	return undef unless $config && $self;

	main::DEBUGLOG && $log->is_debug && $log->debug( Dumper($config) );

	# context that will be used by sysread variants
	my $vars = {
			'outBuf'      => '',      		# buffer of processed audio
			'streaming'   => 1,      		# flag for streaming, changes to 0 when all data received
			'fetching'    => 0,		  		# waiting for HTTP data
			'offset'      => undef,  		# offset for next HTTP request in webm/stream or segment index in dash
			'url'	  	  => $config->{url},
			'retry'       => 5,
	};

	${*$self}{client} = $args->{client};
	${*$self}{song} = $args->{song};
	#${*$self}{url} = $args->{url};
	${*$self}{config} = $config;
	${*$self}{vars} = $vars;
	${*$self}{stash} = $stash;

	# FIXME: overwrite url with what the streamer needs?
	$args->{url} = $config->{url};

	# erase last position from cache
	$cache->remove("yt:lastpos-" . $class->getId($args->{'url'}));

	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{seekdata};
	my $startTime = $seekdata->{timeOffset} || $song->pluginData('lastpos');
	$song->pluginData('lastpos', 0);

	if ($startTime) {
		$song->can('startOffset') ? $song->startOffset($startTime) : ($song->{startOffset} = $startTime);
		$args->{'client'}->master->remoteStreamStartTime(Time::HiRes::time() - $startTime);
	}

	main::INFOLOG && $log->is_info && $log->info("url: $args->{url} starting at: ", int($startTime || 0));

	my $handler = $config->{handler};
	$handler->flush;

	# do format-dependent stuff
	if ( $config->{source} =~ /dash/ ) {
		# set timer for updating the MPD if needed (dash)
		${*$self}{active}  = 1;
		Slim::Utils::Timers::setTimer($self, time() + $config->{'updatePeriod'}, \&updateMPD) if $stash->{updatePeriod};

		# for live stream, always set duration to timeshift depth
		if ($config->{timeShiftDepth}) {
			# only set startOffset when missing startTime or not starting from live edge
			$song->startOffset($config->{timeShiftDepth} - $prefs->get('live_delay')) unless $startTime || !$stash->{liveOffset};
			$song->duration($config->{timeShiftDepth});
			$stash->{startOffset} = $song->startOffset;
		}

		# set starting offset (bytes or index) if not defined yet
		if ($stash->{liveOffset}) {
			$vars->{offset} = $stash->{liveOffset};
		} else {
			$vars->{offset} = 0;
			# use MPD timeline
			if (defined $stash->{'segmentTimeline'}) {
				my $time = 0;
				foreach (@{$stash->{'segmentTimeline'}}) {
					$time += $_->{'d'} / $stash->{'timescale'};
					last if $time >= $startTime;
					$vars->{offset}++;
				}
				main::INFOLOG && $log->is_info && $log->info("using MPD segment timeline for offset");
			}
		}
		main::INFOLOG && $log->is_info && $log->info("MPD index is $vars->{offset}");
	} elsif ( $config->{source} =~ /hls-mpeg/ ) {
		$vars->{offset} = $stash->{fragmentDuration} ? int($startTime / $stash->{fragmentDuration}) : 0;
		main::INFOLOG && $log->is_info && $log->info("HLS (mpeg-ts) index is $vars->{offset} (livestream: $config->{liveStream})");
	} else {
		$handler->getStartOffset($config->{url}, $startTime, sub {
					$vars->{offset} = shift;
					$log->info('Byte offset ', $vars->{offset});
				}
		);
	}

	return $self;
}

sub close {
	my $self = shift;

	# need to disconnect all sessions so that DESTROY is called. It should 
	# not be this way as when {vars} goes out of scope, the reference it 
	# holds on the array of sessions should be the last one
	$_->disconnect foreach @{${*$self}{vars}->{sessions}};
	
	if (${*$self}{config}->{source} =~ /dash/ && ${*$self}{config}->{updatePeriod}) {
		main::INFOLOG && $log->is_info && $log->info("killing MPD update timer");
		Slim::Utils::Timers::killTimers($self, \&updateMPD);
	}

	main::INFOLOG && $log->is_info && $log->info("end of streaming for ", ${*$self}{song}->track->url);

	$self->SUPER::close(@_);
}

sub onStop {
    my ($class, $song) = @_;
	my $config = $song->pluginData('config');
	return if $config->{source} =~ /dash/ && $song->pluginData('stash')->{liveStream};

	my $elapsed = $song->master->controller->playingSongElapsed;
	my $id = Plugins::YouTube::ProtocolHandler->getId($song->track->url);

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
	return $_[1]->pluginData('config')->{'format'};
}

sub contentType {
	return ${*{$_[0]}}{'config'}->{'format'};
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

sub sysread {
	my $self  = $_[0];
	my $v = ${*$self}{'vars'};
	my $config = ${*$self}{'config'};

	# means waiting for offset to be set
	if ( !defined $v->{offset} ) {
		$! = EINTR;
		return undef;
	}

	# call the right sysread
	return $config->{'sysread'}->($v, $config, @_);
}

sub sysread_URL {
	use bytes;

	# now we have a regular sysread callstack
	my $v = shift;
	my $config = shift;
	my $handler = $config->{handler};

	# need more data
	if ( length $v->{outBuf} < MIN_OUT && !$v->{fetching} && $v->{streaming} ) {
		my $url = $v->{url};
		
		# we only use one session in that mode
		my $session = $v->{sessions}->[0] ||= Slim::Networking::Async::HTTP->new;

		my $request = HTTP::Request->new( GET => $url, 
							[ 'Connection', 'keep-alive',
							  'Range', "bytes=$v->{offset}-" . ($v->{offset} + DATA_CHUNK - 1),
							]
		);
		
		$request->protocol( 'HTTP/1.1' );
		
		$v->{fetching} = 1;

		$session->send_request( {
			request => $request,

			onRedirect => sub {
				my $redirect = shift->uri;

				$v->{url} = $redirect;
				main::INFOLOG && $log->is_info && $log->info("being redirected from $url to $redirect using new base $v->{url}");
			},

			onBody => sub {
				my $response = shift->response;

				$handler->addBytes($response->content_ref);
				$v->{fetching} = 0;
				$v->{retry} = 5;

				($v->{length}) = $response->header('content-range') =~ /\/(\d+)$/ unless $v->{length};
				my $len = length $response->content;
				$v->{offset} += $len;
				$v->{streaming} = 0 if ($len < DATA_CHUNK && !$v->{length}) || ($v->{offset} == $v->{length});

				main::DEBUGLOG && $log->is_debug && $log->debug("got chunk length: $len from ", $v->{offset} - $len, " for $url");
			},

			onError => sub {
				$log->warn("error $v->{retry} fetching $url") unless $v->{url} ne $config->{url} && $v->{retry};
				$v->{retry}--;
				$v->{fetching} = 0 if $v->{retry} > 0;
				$v->{url} = $config->{url};
			},
		} );
	}

	# process all available data
	$handler->getAudio(\$v->{outBuf}) if $handler->bufferLength;

	if ( my $bytes = min(length $v->{outBuf}, $_[2]) ) {
		$_[1] = substr($v->{outBuf}, 0, $bytes, '');
		return $bytes;
	} elsif ( $v->{streaming} && $v->{retry} > 0 ) {
		$! = EINTR;
		return undef;
	}

	# end of file streaming
	main::INFOLOG && $log->is_info && $log->info("end streaming");

	return 0;
}

=comment
sub sysread_MPD {
	use bytes;

	# now we have a regular sysread callstack
	my $v = shift;
	my $config = shift;

	my $self  = $_[0];
	my $mpd = ${*$self}{'stash'};
	my $handler = $config->{handler};

	# need more data
	if ( length $v->{outBuf} < MIN_OUT && !$v->{fetching} && $v->{streaming} ) {
		my $url = $v->{url};
		#my $headers = [ 'Connection', 'keep-alive' ];
		my $headers = [ ];
		my $suffix = ${$mpd->{'segmentURL'}}[$v->{offset}]->{media};
		$url .= $suffix;

		my $request = HTTP::Request->new( GET => $url, $headers);
		$request->protocol( 'HTTP/1.1' );

		$v->{fetching} = 1;

		$v->{session}->send_request( {
			request => $request,

			onRedirect => sub {
				my $redirect = shift->uri;

				my $match = (reverse ($suffix) ^ reverse ($redirect)) =~ /^(\x00*)/;
				$v->{url} = substr $redirect, 0, -$+[1] if $match;

				main::INFOLOG && $log->is_info && $log->info("being redirected from $url to $redirect using new base $v->{url}");
			},

			onBody => sub {
				my $response = shift->response;

				$handler->addBytes($response->content_ref);
				$v->{fetching} = 0;
				$v->{retry} = 5;

				$v->{offset}++;
				$v->{streaming} = 0 if $v->{'offset'} == @{$mpd->{segmentURL}};
				main::DEBUGLOG && $log->is_debug && $log->debug("got chunk $v->{offset} length: ", length $response->content, " for $url");
			},

			onError => sub {
				$log->warn("error $v->{retry} fetching $url") unless $v->{url} ne $config->{url} && $v->{retry};
				$v->{retry}--;
				$v->{fetching} = 0 if $v->{retry} > 0;
				$v->{baseURL} = $config->{url};
			},
		} );
	}

	# process all available data
	$handler->getAudio(\$v->{outBuf}) if $handler->bufferLength;

	if ( my $bytes = min(length $v->{outBuf}, $_[2]) ) {
		$_[1] = substr($v->{outBuf}, 0, $bytes, '');
		return $bytes;
	} elsif ( ($v->{streaming} || $mpd->{updatePeriod}) && $v->{retry} > 0 ) {
		$! = EINTR;
		return undef;
	}

	# end of streaming and make sure timer is not running
	main::INFOLOG && $log->is_info && $log->info('end streaming');
	$mpd->{updatePeriod} = 0;

	return 0;
}
=cut

sub sysread_HLS_MPEG {
	use bytes;

	# now we have a regular sysread callstack
	my $v = shift;
	my $config = shift;

	my $self  = $_[0];
	my $mpeg = ${*$self}{stash};
	my $handler = $config->{handler};
	my $fragments = $mpeg->{fragments};
	my $total = scalar @$fragments;

	# end of current segment, get next one
	if ( length $v->{outBuf} < MIN_OUT && !$v->{fetching} && $v->{streaming}) {
		my $url;

		# get next fragment or request a new set for livestream
		if ($config->{liveStream}) {
			$url = shift @$fragments;

			# time to get fresh fragments
			if (!$url && time() > $mpeg->{nextFetch}) {
				$v->{fetching} = 1;
				main::INFOLOG && $log->is_info && $log->info("getting live fragments (index: $mpeg->{nextIndex})");

				getHLSFragments( $mpeg->{url}, sub {
					my $data = shift;
					my $count = @{$data->{fragments}};

					# live stream might end for any reason
					$v->{streaming} = 0 unless $count;
					$v->{fetching} = 0;

					# remove already acquired indexes and wait at least 1 duration
					$mpeg->{nextFetch} = time() + $data->{fragmentDuration};
					splice @{$data->{fragments}}, 0, $mpeg->{nextIndex} - $data->{index};
					return unless @{$data->{fragments}};

					$mpeg->{nextIndex} = $data->{index} + $count;
					$mpeg->{fragments} = $data->{fragments};
					$mpeg->{fragmentDuration} = $data->{fragmentDuration};
					$mpeg->{nextFetch} += $mpeg->{fragmentDuration} * ($count - 3) if $count > 3;

					main::INFOLOG && $log->is_info && $log->info("got $count live fragments of $mpeg->{fragmentDuration}s (index: $mpeg->{nextIndex})");
				} );
			}

			# if we are waiting for time, output audio normally
			goto AUDIO unless $url;
		} else {
			$url = $fragments->[$v->{offset}];
			main::DEBUGLOG && $log->is_debug && $log->debug("fragment $url");
		}

		$v->{fetching} = 1;

		# we might have no base on fragment's url
		$mpeg->{url} =~ m|(^https://[^/]+/)|;
		$url = $url . $1 unless $url =~ /^https/;

		$self->sendRequest($url, 0, 
				sub {
					$v->{fetching} = 0;
					$v->{retry} = 5;
					$v->{offset}++;
					$v->{streaming} = 0 if $v->{offset} == $total && !$config->{liveStream};
					$handler->addBytes(shift->response->content_ref);
					main::DEBUGLOG && $log->is_debug && $log->debug("received $v->{offset}/$total, buffered bytes: ", $handler->bufferLength);
				},
				sub {
					# in case of error, just erase all sessions and restart fresh. Undefining 
					# the array's reference should be enough to have DESTROY called...
					$_->disconnect foreach @{$v->{sessions}};
					$v->{sessions} = undef;
					
					$v->{fetching} = 0;
					$v->{retry} = $v->{offset} < $total - 1 ? $v->{retry} - 1 : 0;
					$log->error("cannot open session for $url ($_[1])");
				},
		);
	}

AUDIO:
	$handler->getAudio(\$v->{outBuf}) if $handler->bufferLength;

	if ( my $bytes = min(length $v->{outBuf}, $_[2]) ) {
		$_[1] = substr($v->{outBuf}, 0, $bytes, '');
		return $bytes;
	} elsif ( $v->{streaming} ) {
		$! = EINTR;
		return undef;
	}

	return 0;
}

sub sendRequest {
	my ($self, $url, $level, $onBody, $onError) = @_;
	my $v = ${*$self}{vars};
		
	my $request = HTTP::Request->new( GET => $url, [ 'Connection', 'keep-alive' ] );
	# my $request = HTTP::Request->new( GET => $url );
	$request->protocol( 'HTTP/1.1' );
	
	my ($host) = $url =~ m|(^https://[^/]+/)?(.*)$|;
	my $session = $v->{sessions}->[$level];	
	
	if (!$session) {
		# if we have not reached that level, create a session and proceed
		main::INFOLOG && $log->is_info && $log->info("creating new session at level $level to $host");
		$session = $v->{sessions}->[$level] = Plugins::YouTube::HTTP->new;
	} elsif ($session->request->uri !~ /$host/) {
		# if we point to the wrong host, we have to disconnect everything 
		# below us and for good measure erase these.
		main::INFOLOG && $log->is_info && $log->info("discarding non-matching session at level $level to $host");
		$_->disconnect foreach @{$v->{sessions}}[ $level .. $#{$v->{sessions}} ];
		splice @{$v->{sessions}}, $level + 1;
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug("using session at level $level to $host");
	}
	
	$session->send_request( {
		request => $request,

		onRedirect => sub {
			my $redir = shift->uri;
			# the YouTube::HTTP package will refuse disconnect if it detects a redirect 
			# and block the send_request so that we don't follow and recurse
			$session->request->uri($url);
			$self->sendRequest($redir, ++$level, $onBody, $onError);
		},

		onBody => sub {
			main::DEBUGLOG && $log->is_debug && $log->debug("received body of ", length $_[0]->response->content);			
			$onBody->(@_);
		},	

		onError => sub {
			$log->error("error $_[1]");			
			$onError->(@_);
		}
	} );
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

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb,) = @_;

	my $yt_dlp = Plugins::YouTube::Utils::yt_dlp_bin($prefs->get('yt_dlp'));
	$log->info("Using yt_dlp $yt_dlp");
	return $_[3]->("cannot find yt-dlp") unless $yt_dlp;

	my $masterUrl = $song->track()->url;

	$song->pluginData(lastpos => ($masterUrl =~ /&lastpos=([\d]+)/)[0] || 0);
	$masterUrl =~ s/&.*//;

	my $now = time();
	my $id = $class->getId($masterUrl);
	my $url = "http://www.youtube.com/watch?v=$id";
	main::INFOLOG && $log->is_info && $log->info("next track id: $id url: $url master: $masterUrl");

	if (main::ISWINDOWS) {
		# this is all bad but IPC::open2/3 or AnyEvent::run_cmd, or any other solution do not work under
		# Windows because 1/ Windows cannot do select() on handles and 2/ LMS has a tie on stdio and all
		# these functions want to re-define stdio. So only a dirty polling solution works and for now I'll
		# use that on all platforms.
		my $pid = 0;
		my $lambda;
		my $out = tmpnam();
		my $cmd = qq{$yt_dlp -j $url >$out};

		$log->info("Get tracks with $cmd");

		eval {
			Win32::Process::Create( $pid,
				$ENV{COMSPEC}, "/c $cmd",
				0, Win32::Process::NORMAL_PRIORITY_CLASS(), '.',
			);
		};

		$lambda = sub {
			my $pid = shift;
			$pid->GetExitCode(my $exitcode);
			return Slim::Utils::Timers::setTimer($pid, Time::HiRes::time() + 0.25, $lambda) if $exitcode == Win32::Process::STILL_ACTIVE();

			# response is on 1st line
			local @ARGV = ($out);
			my $tracks = <>;

			main::INFOLOG && $log->is_info && $log->info("yt-dlp finished with $exitcode in ", time() - $now, " seconds");
			$tracks = eval { decode_json($tracks) };

			$log->error("yt-dlp failed") && $errorCb->($@) && return if $@ || !$tracks;

			# duration is at the top level
			$song->track->secs( $tracks->{'duration'} );

			_getNextTrack($class, $song, $successCb, $errorCb, _selectTracks($tracks->{formats}));
		};

		Slim::Utils::Timers::setTimer($pid, Time::HiRes::time() + 0.25, $lambda);
	} else {

		my $cv = AnyEvent::Util::run_cmd(
			[ $yt_dlp, '-j', $url],
			"<", "/dev/null",
			">" , \my $tracks,
			"2>", \my $err,
		);

		$cv->cb( sub {
			main::INFOLOG && $log->is_info && $log->info("yt-dlp finished in ", time() - $now, " seconds");
			$tracks = eval { decode_json($tracks) };

			$log->error("yt-dlp failed $err") && $errorCb->($@) && return if $@ || !$tracks;

			# duration is at the top level
			$song->track->secs( $tracks->{'duration'} );

			_getNextTrack($class, $song, $successCb, $errorCb, _selectTracks($tracks->{formats}));
		});
	}
}

sub _selectTracks{
	my $tracks = shift;

	state $sorted = 0;
	unless ($sorted) {
		@audioId = sort { $a->{rate} < $b->{rate} } @audioId;
		@videoId = sort { $a->{prio} < $b->{prio} } @videoId;
		$sorted = 1;
	}

	my $codecs = $prefs->get('aac') ? 'aac' : '';
	$codecs .= '_ogg' if $prefs->get('vorbis');
	$codecs .= '_ops' if $prefs->get('opus');
	my @selected = ();

	# only use native language (no AI translation)
	$tracks = [ grep { $_->{format_id} =~ /^(\d+)(?:-drc)?$/ } @$tracks ];
	my $count = @$tracks;

	main::DEBUGLOG && $log->is_debug && $log->debug(Dumper($tracks));

	# find all usable tracks with audio only
	foreach my $item (@audioId) {
		next unless $codecs =~ /$item->{codec}/;
		my ($track) = grep { $_->{format_id} =~ /^$item->{id}/ } @$tracks;
		push @selected, $track if $track;
		$track->{_id} = $item;
	}

	# add video if allowed
	if ($prefs->get('use_video')) {
		foreach my $item (@videoId) {
			my ($track) = grep { $_->{format_id} =~ /^$item->{id}/ } @$tracks;
			push @selected, $track if $track;
			$track->{_id} = $item;
		}
	}

	main::INFOLOG && $log->is_info && $log->info("selected ", scalar @selected, "/$count tracks");

	return \@selected;
}

# fetch the YouTube player url and extract a playable stream
sub _getNextTrack {
	my ($class, $song, $successCb, $errorCb, $tracks) = @_;
	my $masterUrl = $song->track()->url;

	$song->pluginData(lastpos => ($masterUrl =~ /&lastpos=([\d]+)/)[0] || 0);
	$masterUrl =~ s/&.*//;

	my $track = shift @$tracks;

	# need at least one track, if this one fails, we'll call ourself
	unless ($track) {
		$log->error("No matching track");
		return $errorCb->();
	}

	main::INFOLOG && $log->is_info && $log->info("next track format: $track->{_id}->{id} id: ", $class->getId($masterUrl));
	main::DEBUGLOG && $log->is_debug && $log->debug(Dumper($track));

	my $config = {
		format => $track->{_id}->{codec},
		bitrate => $track->{_id}->{rate} || 0,
		# this is shallow copy
		headers => $track->{http_headers},
		url => $track->{url},
	};

	# this is a reference, we'll continue to modify it later
	$song->pluginData(config => $config);

	# What type of stream do we have?
	if (!$track->{manifest_url}) {
		my $handler = $config->{'format'} =~ /aac/ ?
							Plugins::YouTube::M4a->new($track->{url}) :
							Plugins::YouTube::WebM->new($track->{url});

		$config->{'handler'} = $handler;
		$config->{'sysread'} = \&sysread_URL;

		# if we failed, we'll call ourselves to consume next track in YT's offering
		$handler->initialize(
				sub {
					updateMetadata($handler, $song, $track);
					$successCb->();
				},
				sub {
					$log->warn("failed track, trying next YouTube offering");
					_getNextTrack($class, $song, $successCb, $errorCb, $tracks);
				}
		);
	} else {
		# this is HLS-MPEG, I don't think there is HLS-AAC as we have selected only 92..95 for format
		# otherwise, look at my FranceTV plugin for HLS-AAC support
		main::DEBUGLOG && $log->is_debug && $log->debug("Using manifest url $track->{manifest_url}");

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $response = shift;
				my $m3u8 = $response->content;

				main::DEBUGLOG && $log->is_debug && $log->debug($m3u8);

				# using HE-AAC is possible, AAC-LC otherwise and always lowest total BW
				my ($acodec) = $m3u8 =~ /(mp4a.40.2)/ ? $1 : 'mp4a.40.5';
				my ($bandwidth, $base, $path);

				for my $item ( split (/#EXT-X-STREAM-INF/, $m3u8) ) {
					# be careful that this INF might contain a relative path
					next unless $item =~ /$acodec/ && $item =~ m|\S+BANDWIDTH=(\d+).*\n(^https://[^/]+/)?(\S+)$|m;
					next if $bandwidth && $1 > $bandwidth;
					($bandwidth, $base, $path) = ($1, $2, $3);
				}

				# streams url might be relative, so use the manifest's base then
				($base) = $track->{manifest_url} =~ m|(^https://[^/]+/)| unless $base;
				my $url = $base . $path;

				#$log->info("HLS mpeg-ts bandwidth $bandwidth (codec: $acodec) with url $url");
				getHLSFragments($url, sub {
						my $data = shift;
						return $errorCb->("Can't get fragments for $url") unless $data;

						my $mpeg;
						$mpeg->{fragmentDuration} = $data->{fragmentDuration};
						$mpeg->{nextIndex} = $data->{index} ? $data->{index} + @{$data->{fragments}} : 0;
						$mpeg->{fragments} = $data->{fragments};
						$mpeg->{url} = $url;

						# stash that into pluginData to retrieve it later
						$song->pluginData(stash => $mpeg);

						my $handler = Plugins::YouTube::MPEGTS->new( $track->{url} );

						$config->{source} = 'hls-mpeg';
						$config->{handler} = $handler;
						$config->{liveStream} = ($data->{index} > 0) || 0;
						$config->{sysread} = \&sysread_HLS_MPEG;

						$handler->initialize(
							sub {
								updateMetadata($handler, $song, $track);
								$successCb->();
							},
							sub {
								$log->warn("failed track, trying next YouTube offering");
								_getNextTrack($class, $song, $successCb, $errorCb, $tracks);
							},
							$data->{fragments}->[0],
						);
					}
				);
			},

			sub {
				$log->error("could not get manifest url, $_[1]");
				$errorCb->("manifest error");
			},

		)->get($track->{manifest_url});
	}
}

sub updateMetadata {
	my ($handler, $song, $track) = @_;
	$song->track->bitrate( $handler->bitrate || ($track->{abr} || $track->{vbr}) * 1000 || $track->{_id}->{rate} );
	$song->track->samplerate( $handler->samplerate || $track->{asr} );
	$song->track->channels( $handler->channels || $track->{audio_channels} );
	$song->track->secs( $handler->duration ) if $handler->can('duration') && $handler->duration;
	#$song->track->samplesize(  );

	my $id = __PACKAGE__->getId($song->track->url);
	if (my $meta = $cache->get("yt:meta-$id")) {
		$meta->{type} = "YouTube ($track->{_id}->{codec}@" . $song->track->samplerate . 'Hz)';
		$cache->set("yt:meta-$id", $meta);
		main::INFOLOG && $log->is_info && $log->info("Updating metadata cache for $id");
	}

	$song->master->currentPlaylistUpdateTime( Time::HiRes::time() );
	Slim::Control::Request::notifyFromArray( $song->master, [ 'newmetadata' ] );
	main::INFOLOG && $log->is_info && $log->info("Updated song metadata for $id");
}

sub getHLSFragments {
	my ($url, $cb) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $m3u8 = shift->content;
			my $data;

			$cb->() unless $m3u8;

			$m3u8 =~ /^#EXT-X-MEDIA-SEQUENCE:(\d+)/m;
			$data->{'index'} = $1 || 0;

			$m3u8 =~ /^#EXT-X-TARGETDURATION:(\d+)/m;
			$data->{'fragmentDuration'} = $1 || 0;

			my @fragments;
			for my $item ( split (/#EXTINF/, $m3u8) ) {
				# FIXME: this regex might need some changes
				next unless $item =~ /[^\n]*\n(\S+\.ts$)/m;
				push @fragments, $1;
			}

			# fragments might have no base
			$data->{fragments} = \@fragments;
			$cb->($data);
		},

		sub {
			$log->error("could not get fragments $_[1]");
			$cb->();
		},

	)->get($url);
}

=comment
	# don't forget to send initializeURL to the initialize methods of m4a
	main::INFOLOG && $log->is_info && $log->info("using initialize url $props->{'initializeURL'}");
	$url .= $props->{'initializeURL'};
	$song->track->secs( $props->{'duration'} );

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
=cut

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
