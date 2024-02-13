package Plugins::YouTube::API;

use strict;

use Digest::MD5 qw(md5_hex);
use File::Spec::Functions qw(catdir);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max);
use URI::Escape qw(uri_escape uri_escape_utf8);
use MIME::Base64 qw(decode_base64);

use constant API_URL => 'https://www.googleapis.com/youtube/v3/';
use constant DEFAULT_CACHE_TTL => 24 * 3600;
use constant DEFAULT_API_KEY => 'QUl6YVN5Qi1wd1B0RGt4RjZKUW1BOHFxOWgxbWQ2ME15STVRNWlB';

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.youtube');
my $log   = logger('plugin.youtube');
my $cache = Slim::Utils::Cache->new();

sub flushCache { $cache->cleanup(); }

sub search {
	my ( $class, $cb, $args ) = @_;

	$args ||= {};
	$args->{part} = 'snippet';
	$args->{type} ||= 'video';
	$args->{order} ||= $prefs->get('search_rank');
	$args->{relevanceLanguage} = Slim::Utils::Strings::getLanguage();

	_pagedCall('search', $args, $cb);
}

sub searchDirect {
	my ( $class, $type, $cb, $args ) = @_;

	$args ||= {};
	$args->{_noRegion} = 1;

	_pagedCall( $type, $args, $cb);
}

sub getCategories {
	my ( $class, $type, $cb, $args ) = @_;

	$args ||= {};
	$args->{hl} = Slim::Utils::Strings::getLanguage();
	$args->{_cache_ttl} = 7 * 86400;

	_pagedCall($type, $args, $cb);
}

sub getVideoDetails {
	my ( $class, $cb, $ids ) = @_;

	_call('videos', {
		part => 'snippet,contentDetails',
		id   => $ids,
		# cache video details a bit longer
		_cache_ttl => 7 * 86400,
	}, $cb);
}

sub _pagedCall {
	my ( $method, $args, $cb ) = @_;
	my $wantedItems = $args->{_quantity} || $prefs->get('max_items');
	# ignore $args->{_index} and let LMS handle offset
	my $wantedIndex = 0;
	my @items;
	my $pagingCb;
	my $pageIndex = 0;
	
	# we want them starting from current index
	$wantedItems += $args->{_index} || 0;

	main::INFOLOG && $log->info("Searching by [$args->{order}]");
	main::INFOLOG && $log->info("Querying [$args->{_quantity}] from [$args->{_index}] to [", $wantedItems-1, "] using [$method]");

	# doing a search with a display order, so need to give precedence to 'query_size'
	if ($prefs->get('search_sort') || $prefs->get('channel_sort') || $prefs->get('playlist_sort')) {
		$wantedItems = (int(($wantedItems - 1) / $prefs->get('query_size')) + 1) * $prefs->get('query_size');
		main::INFOLOG && $log->info("Stretching quantity to [$wantedItems] due to sorting");
	}
	
	# that the maximum we'll get anyway
	$wantedItems = $prefs->get('max_items') if $wantedItems > $prefs->get('max_items');

	$pagingCb = sub {
		my $results = shift;

		if ( $results->{error} || !$results->{items} ) {
			$log->error("no results");
			$cb->( { items => undef, total => 0 } ) if ( $results->{error} );
			return;
		}

		push @items, @{$results->{items}};
		$pageIndex += scalar @{$results->{items}};

		main::INFOLOG && $log->info("Want $wantedItems items from offset ", $wantedIndex, ", have " . scalar @items . " so far [acquired $pageIndex]");

		if (@items < $wantedItems && $results->{nextPageToken}) {
			$args->{pageToken} = $results->{nextPageToken};
			main::INFOLOG && $log->info("Get next page using token " . $args->{pageToken});
			_call($method, $args, $pagingCb);
		} else {
			my $total = min($results->{'pageInfo'}->{'totalResults'} || $pageIndex, $prefs->get('max_items'));
			main::INFOLOG && $log->info("Got all we wanted, return " . scalar @items . "/$total. (YT total ", $results->{'pageInfo'}->{'totalResults'} || 'N/A', ")");
			$cb->( { items => \@items, offset => $wantedIndex, total  => $total } );
		}
	};

	_call($method, $args, $pagingCb);
}

sub _call {
	my ( $method, $args, $cb ) = @_;

    my $API_KEY = $prefs->get('APIkey') || MIME::Base64::decode_base64(DEFAULT_API_KEY);
	my $url = '?' . ($args->{_noKey} ? '' : 'key=' . $API_KEY . '&');

	$args->{regionCode} ||= $prefs->get('country') unless $args->{_noRegion};
	$args->{part}       ||= 'snippet' unless $args->{_noPart};
	$args->{maxResults} ||= 50;

	for my $k ( sort keys %{$args} ) {
		next if $k =~ /^_/;
		$url .= $k . '=' . URI::Escape::uri_escape_utf8( Encode::decode( 'utf8', $args->{$k} ) ) . '&';
	}

	$url =~ s/&$//;
	$url = API_URL . $method . $url;

	my $cacheKey = $args->{_noCache} ? '' : md5_hex($url);

	if ( $cacheKey && (my $cached = $cache->get($cacheKey)) ) {
		main::INFOLOG && $log->info("Returning cached data for: $url");
		$cb->($cached);
		return;
	}

	main::INFOLOG && $log->info("Calling API (will cache for ", $args->{_cache_ttl} || DEFAULT_CACHE_TTL, "s): $url");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $result = eval { from_json($response->content) };

			if ($@) {
				$log->error(Data::Dump::dump($response)) unless main::DEBUGLOG && $log->is_debug;
				$log->error($@);
			}

			main::DEBUGLOG && $log->is_debug && warn Data::Dump::dump($result);

			$result ||= {};
			$cache->set($cacheKey, $result, $args->{_cache_ttl} || DEFAULT_CACHE_TTL);

			$cb->($result);
		},

		sub {
			warn Data::Dump::dump(@_);
			$log->error($_[1]);
			$cb->( { error => $_[1] } );
		},

		{
			timeout => 15,
		}

	)->get($url);
}

1;