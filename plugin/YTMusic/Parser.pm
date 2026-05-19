package Plugins::YouTube::YTMusic::Parser;

# JSON walker for the youtubei/v1/next + browse responses.

use strict;
use warnings;

# navigate a path. each step is a hash key or array index.
sub _nav {
	my ($data, @path) = @_;
	for my $step (@path) {
		return undef unless defined $data;
		if (ref($data) eq 'HASH') {
			return undef unless $step =~ /^[a-zA-Z_]/;
			$data = $data->{$step};
		} elsif (ref($data) eq 'ARRAY') {
			return undef unless $step =~ /^-?\d+$/;
			$data = $data->[$step];
		} else {
			return undef;
		}
	}
	return $data;
}

# largest square cover, fallback to the last thumbnail
sub _bestCover {
	my ($thumbs) = @_;
	return undef unless ref($thumbs) eq 'ARRAY' && @$thumbs;
	my $square;
	for my $t (@$thumbs) {
		next unless $t->{url};
		$square = $t->{url} if ($t->{width} || 0) == ($t->{height} || 0);
	}
	return $square || $thumbs->[-1]->{url};
}

# longBylineText runs: artist runs have UC browseIds, album runs MPRE,
# year is a 4-digit string.
sub _parseRuns {
	my ($runs) = @_;
	return {} unless ref($runs) eq 'ARRAY';

	my (@artists, $album, $year);
	for my $r (@$runs) {
		my $text = $r->{text};
		next unless defined $text;
		# separators
		next if $text =~ /^\s*[\x{2022}\x{00b7}\x{2027}\xc2\xb7\xe2\x80\xa2]\s*$/ || $text =~ /^\s*\.\s*$/ || $text eq ' \x{2022} ';
		next if $text =~ /^\s*(?:\xe2\x80\xa2|\xc2\xb7)\s*$/;
		next if $text =~ /^\s+$/;

		my $browseId = _nav($r, 'navigationEndpoint', 'browseEndpoint', 'browseId');
		if ($browseId) {
			if ($browseId =~ /^MPRE/) {
				$album = $text;
			} elsif ($browseId =~ /^UC/) {
				push @artists, $text;
			}
			next;
		}
		if ($text =~ /^\d{4}$/) {
			$year = $text;
			next;
		}
		# duration runs (3:42), ignore
		next if $text =~ /^\d+:\d+(?::\d+)?$/;
		# artist without id
		push @artists, $text if length($text) > 1;
	}

	return {
		artist => @artists ? join(', ', @artists) : undef,
		album  => $album,
		year   => $year,
	};
}

# find the playlistPanelVideoRenderer for $videoId. usually first entry.
sub _findPanelVideo {
	my ($resp, $videoId) = @_;
	my $contents = _nav($resp,
		'contents', 'singleColumnMusicWatchNextResultsRenderer',
		'tabbedRenderer', 'watchNextTabbedResultsRenderer',
		'tabs', 0, 'tabRenderer', 'content',
		'musicQueueRenderer', 'content', 'playlistPanelRenderer', 'contents',
	);
	return undef unless ref($contents) eq 'ARRAY';

	for my $entry (@$contents) {
		my $r = $entry->{playlistPanelVideoRenderer}
		     || _nav($entry, 'playlistPanelVideoWrapperRenderer', 'primaryRenderer', 'playlistPanelVideoRenderer');
		next unless $r;
		return $r if ($r->{videoId} || '') eq $videoId;
	}
	# id didnt match (live mix etc), take the first
	for my $entry (@$contents) {
		my $r = $entry->{playlistPanelVideoRenderer}
		     || _nav($entry, 'playlistPanelVideoWrapperRenderer', 'primaryRenderer', 'playlistPanelVideoRenderer');
		return $r if $r;
	}
	return undef;
}

sub _findLyricsBrowseId {
	my ($resp) = @_;
	my $tabs = _nav($resp,
		'contents', 'singleColumnMusicWatchNextResultsRenderer',
		'tabbedRenderer', 'watchNextTabbedResultsRenderer',
		'tabs',
	);
	return undef unless ref($tabs) eq 'ARRAY';
	for my $tab (@$tabs) {
		my $bid = _nav($tab, 'tabRenderer', 'endpoint', 'browseEndpoint', 'browseId');
		return $bid if $bid && $bid =~ /^MPLYt/;
	}
	return undef;
}

sub parseWatchResponse {
	my ($resp, $videoId) = @_;
	return {} unless ref($resp) eq 'HASH' && $videoId;

	my $panel = _findPanelVideo($resp, $videoId);
	return {} unless $panel;

	my $title = _nav($panel, 'title', 'runs', 0, 'text');
	my $runs  = _nav($panel, 'longBylineText', 'runs');
	my $info  = _parseRuns($runs);
	my $cover = _bestCover( _nav($panel, 'thumbnail', 'thumbnails') );

	my $videoType = _nav($panel,
		'navigationEndpoint', 'watchEndpoint',
		'watchEndpointMusicSupportedConfigs',
		'watchEndpointMusicConfig', 'musicVideoType',
	);

	my $lyricsBrowseId = _findLyricsBrowseId($resp);

	my %out = (
		title          => $title,
		artist         => $info->{artist},
		album          => $info->{album},
		year           => $info->{year},
		cover          => $cover,
		videoType      => $videoType,
		lyricsBrowseId => $lyricsBrowseId,
	);
	delete $out{$_} for grep { !defined $out{$_} } keys %out;
	return \%out;
}

sub parseLyricsResponse {
	my ($resp) = @_;
	return undef unless ref($resp) eq 'HASH';
	my $text = _nav($resp,
		'contents', 'sectionListRenderer', 'contents', 0,
		'musicDescriptionShelfRenderer', 'description', 'runs', 0, 'text',
	);
	return $text;
}

1;
