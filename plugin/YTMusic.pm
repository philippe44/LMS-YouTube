package Plugins::YouTube::YTMusic;

# async client for music.youtube.com/youtubei/v1. unofficial endpoint,
# stable for years. gets us artist/album/year/cover/lyrics that the
# public v3 Data API doesnt return.

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Digest::MD5 qw(md5_hex);

use Plugins::YouTube::YTMusic::Parser;

my $log   = logger('plugin.youtube');
my $cache = Slim::Utils::Cache->new();

use constant ENDPOINT_BASE => 'https://music.youtube.com/youtubei/v1/';
# innertube key, hardcoded in every music.youtube.com page
use constant INNERTUBE_KEY => 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
use constant CACHE_TTL     => 7 * 86400;
use constant FAIL_TTL      => 600;
# cap so we dont starve the shared async http pool, playback needs it too
use constant MAX_PARALLEL  => 4;

my %inFlight;
my @queue;
my $running = 0;

sub _kickQueue {
	while ($running < MAX_PARALLEL && @queue) {
		my $next = shift @queue;
		_run(@$next);
	}
}

sub _context {
	my @t = gmtime;
	my $cv = sprintf('1.%04d%02d%02d.01.00', $t[5]+1900, $t[4]+1, $t[3]);
	return {
		client => { clientName => 'WEB_REMIX', clientVersion => $cv, hl => 'en', gl => 'US' },
		user   => {},
	};
}

sub _post {
	my ($endpoint, $body, $cb) = @_;

	my $url = ENDPOINT_BASE . $endpoint . '?key=' . INNERTUBE_KEY . '&prettyPrint=false';
	$body->{context} = _context();

	my $json = eval { to_json($body) };
	if ($@) {
		$log->error("ytm: failed to encode body: $@");
		$cb->(undef);
		return;
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $result = eval { from_json($response->content) };
			if ($@) {
				$log->error("ytm: bad json: $@");
				$cb->(undef);
				return;
			}
			$cb->($result);
		},
		sub {
			$log->warn("ytm: $endpoint failed: " . ($_[1] || 'unknown'));
			$cb->(undef);
		},
		{ timeout => 15 },
	)->post(
		$url,
		'Content-Type' => 'application/json',
		'Origin'       => 'https://music.youtube.com',
		'User-Agent'   => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 LMS-YouTube',
		$json,
	);
}

# returns { artist, album, year, cover, lyricsBrowseId, videoType } or undef
sub getMusicMetadata {
	my ($class, $videoId, $cb) = @_;

	my $failKey = "ytm:fail-$videoId";
	if ($cache->get($failKey)) {
		$cb->(undef);
		return;
	}

	my $cacheKey = "ytm:meta-$videoId";
	if (my $cached = $cache->get($cacheKey)) {
		$cb->($cached);
		return;
	}

	# in flight already, next bulk poll will pick it up
	if ($inFlight{$videoId}) {
		$cb->(undef);
		return;
	}

	if ($running >= MAX_PARALLEL) {
		push @queue, [ $videoId, $cb ];
		return;
	}
	_run($videoId, $cb);
}

sub _run {
	my ($videoId, $cb) = @_;
	my $failKey  = "ytm:fail-$videoId";
	my $cacheKey = "ytm:meta-$videoId";

	$inFlight{$videoId} = 1;
	$running++;
	main::INFOLOG && $log->is_info && $log->info("ytm: fetch $videoId ($running in flight, " . scalar(@queue) . " queued)");

	_post('next', {
		videoId    => $videoId,
		playlistId => 'RDAMVM' . $videoId,
		enablePersistentPlaylistPanel => JSON::XS::true,
		isAudioOnly                    => JSON::XS::true,
	}, sub {
		my $resp = shift;
		delete $inFlight{$videoId};
		$running--;

		my $result;
		if (!$resp) {
			$cache->set($failKey, 1, FAIL_TTL);
		} else {
			my $parsed = Plugins::YouTube::YTMusic::Parser::parseWatchResponse($resp, $videoId);
			if ($parsed && %$parsed) {
				$cache->set($cacheKey, $parsed, CACHE_TTL);
				$result = $parsed;
			} else {
				$cache->set($failKey, 1, FAIL_TTL);
			}
		}

		$cb->($result);
		_kickQueue();
	});
}

# plain text lyrics for an MPLYt... browseId
sub getLyrics {
	my ($class, $browseId, $cb) = @_;

	return $cb->(undef) unless $browseId && $browseId =~ /^MPLYt/;

	my $cacheKey = "ytm:lyrics-$browseId";
	if (my $cached = $cache->get($cacheKey)) {
		$cb->($cached);
		return;
	}

	_post('browse', {
		browseId => $browseId,
	}, sub {
		my $resp = shift;
		unless ($resp) {
			$cb->(undef);
			return;
		}

		my $text = Plugins::YouTube::YTMusic::Parser::parseLyricsResponse($resp);
		$cache->set($cacheKey, $text, CACHE_TTL) if defined $text;
		$cb->($text);
	});
}

1;
