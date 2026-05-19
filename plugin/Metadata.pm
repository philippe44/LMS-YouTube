package Plugins::YouTube::Metadata;

# helpers for v3 video items. v3 has no album/year/artist fields,
# we dig artist/album/year out of the description block when YT
# Music auto-generated it.

use strict;
use warnings;

use Slim::Utils::Log;

my $log = logger('plugin.youtube');

use constant CATEGORY_MUSIC => 10;

# "Artist - Title" split. returns (artist, title, fulltitle) or
# (undef, $title, undef).
sub parseDashTitle {
	my ($title) = @_;
	return (undef, $title, undef) unless defined $title;

	if ($title =~ /^(.+?)\s+-\s+(.+)$/) {
		return ($1, $2, $title);
	}
	return (undef, $title, undef);
}

# the auto-generated YT Music "Provided to YouTube by..." block.
# shape:
#   Provided to YouTube by <distributor>
#   <title> . <artist1> . <artist2>
#   <album>
#   . YYYY <label>
#   Released on: YYYY-MM-DD
# middot is U+00B7. we also accept " - " and " / " because some
# uploaders use those.
sub parseYTMusicDescription {
	my ($desc) = @_;
	return {} unless defined $desc && length $desc;
	return {} unless $desc =~ /Provided to YouTube by/i;

	my @lines = grep { /\S/ } split /\n/, $desc;
	shift @lines if @lines && $lines[0] =~ /Provided to YouTube by/i;

	return {} unless @lines >= 2;

	my $titleLine = $lines[0];
	my $album     = $lines[1];

	my @parts = split /\s*(?:\x{00b7}|\xc2\xb7|·| - | \/ )\s*/, $titleLine;
	return {} unless @parts >= 2;

	my $title  = shift @parts;
	my $artist = join(', ', @parts);

	s/^\s+|\s+$//g for ($title, $artist, $album);

	my $year;
	for my $ln (@lines) {
		if ($ln =~ /Released on:\s*(\d{4})/) {
			$year = $1;
			last;
		}
		if ($ln =~ /^\s*(?:\x{00b7}|\xc2\xb7|·|\xe2\x84\x97|\(P\))\s*(\d{4})\b/) {
			$year ||= $1;
		}
	}

	return {
		title  => $title,
		artist => $artist,
		album  => $album,
		year   => $year,
	};
}

# topic categories are wikipedia URLs like .../wiki/Pop_music.
# trim to "Pop music". drop the generic "Music" entry, useless tag.
sub topicCategoriesToGenre {
	my ($topicDetails) = @_;
	return undef unless ref($topicDetails) eq 'HASH';
	my $cats = $topicDetails->{topicCategories};
	return undef unless ref($cats) eq 'ARRAY' && @$cats;

	my @names;
	for my $url (@$cats) {
		next unless $url =~ m{/wiki/([^/]+)$};
		my $name = $1;
		$name =~ s/_/ /g;
		$name =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
		next if $name eq 'Music';
		push @names, $name;
	}

	return undef unless @names;
	return join(', ', @names);
}

# ISO 8601 2024-08-23T14:00:00Z to "2024"
sub yearFromPublishedAt {
	my ($publishedAt) = @_;
	return undef unless defined $publishedAt;
	return $1 if $publishedAt =~ /^(\d{4})/;
	return undef;
}

# v3 item to flat metadata hash. each field is best-effort.
sub buildFromV3Item {
	my ($item) = @_;
	return {} unless ref($item) eq 'HASH';

	my $snippet = $item->{snippet}    || {};
	my $content = $item->{contentDetails} || {};
	my $topics  = $item->{topicDetails}   || {};

	my ($artist, $title, $fulltitle) = parseDashTitle($snippet->{title});

	# description block beats the dash split if its there
	my $ytm = parseYTMusicDescription($snippet->{description});
	my $album;
	my $year;

	if ($ytm->{title}) {
		$title     = $ytm->{title};
		$fulltitle = $snippet->{title};
		$artist    = $ytm->{artist} if $ytm->{artist};
		$album     = $ytm->{album};
		$year      = $ytm->{year};
	}

	$artist ||= $snippet->{channelTitle};
	$year   ||= yearFromPublishedAt($snippet->{publishedAt});

	my $genre = topicCategoriesToGenre($topics);
	$genre ||= 'Music' if ($snippet->{categoryId} || 0) == CATEGORY_MUSIC;

	my $duration = $content->{duration};
	my ($misc, $hour, $min, $sec) = $duration =~ /P(?:([^T]*))T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/ if $duration;
	$duration = ($sec || 0) + (($min || 0) * 60) + (($hour || 0) * 3600);

	return {
		title      => $title || '',
		artist     => $artist || '',
		album      => $album,
		year       => $year,
		genre      => $genre,
		duration   => $duration || 0,
		_fulltitle => $fulltitle,
		_snippet   => $snippet,
	};
}

1;
