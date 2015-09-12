package Plugins::YouTube::API;

use strict;

use Digest::MD5 qw(md5_hex);
use File::Spec::Functions qw(catdir);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max);
use URI::Escape qw(uri_escape uri_escape_utf8);

use Data::Dumper;

use constant API_URL => 'https://www.googleapis.com/youtube/v3/';
use constant DEFAULT_CACHE_TTL => 24 * 3600;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.youtube');
my $log   = logger('plugin.youtube');
my $cache = Slim::Utils::Cache->new();

sub flushCache { $cache->cleanup(); }
	
sub search {
	my ( $class, $cb, $upto, $args ) = @_;
	
	$args ||= {};
	$args->{part}       = 'snippet';
	$args->{type}     ||= 'video';
	$args->{relevanceLanguage} = Slim::Utils::Strings::getLanguage();
	
	_pagedCall('search', $args, $cb, $upto);
}

sub searchVideos {
	my ( $class, $cb, $upto, $args ) = @_;
	
	$args ||= {};
	$args->{type} = 'video';
	$class->search($cb, $upto, $args);
}	

sub searchChannels {
	my ( $class, $cb, $upto, $args ) = @_;
	
	$args ||= {};
	$args->{type} = 'channel';
	$class->search($cb, $upto, $args);
}

sub searchPlaylists {
	my ( $class, $cb, $upto, $args ) = @_;
	
	$args ||= {};
	$args->{type} = 'playlist';
	$class->search($cb, $upto, $args);
}

sub getPlaylist {
	my ( $class, $cb, $upto, $args ) = @_;
	
	_pagedCall('playlistItems', {
		playlistId => $args->{playlistId},
		_noRegion  => 1,
	}, $cb, $upto);
}

sub getVideoCategories {
	my ( $class, $cb, $upto ) = @_;
	
	_pagedCall('videoCategories', {
		hl => Slim::Utils::Strings::getLanguage(),
		# categories don't change that often
		_cache_ttl => 7 * 86400,
	}, $cb, $upto);
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
	my ( $method, $args, $cb, $upto ) = @_;
	
	my $maxItems = delete $args->{maxItems} || $prefs->get('max_items');
	my $wantedItems = min($maxItems, $upto || $maxItems);
		
	my $items = [];
		
	my $pagingCb;
	
	$pagingCb = sub {
		my $results = shift;

		push @$items, @{$results->{items}};
		
		main::INFOLOG && $log->info("We want $wantedItems items, have " . scalar @$items . " so far");
		
		if (@$items < $wantedItems && $results->{nextPageToken}) {
			$args->{pageToken} = $results->{nextPageToken};
			main::INFOLOG && $log->info("Get next page using token " . $args->{pageToken});

			_call($method, $args, $pagingCb);
		}
		else {
			my $total = $results->{'pageInfo'}->{'totalResults'} || scalar @$items;
			main::INFOLOG && $log->info("Got all we wanted. Return " . scalar @$items . " items.");
			$results->{items} = $items;
			$results->{total} = min($total, $maxItems);
			$cb->($results);
		}
	};

	_call($method, $args, $pagingCb);
}


sub _call {
	my ( $method, $args, $cb ) = @_;
	
	my $url = '?' . (delete $args->{_noKey} ? '' : 'key=' . $prefs->get('APIkey') . '&');
	
	$args->{regionCode} ||= $prefs->get('country') unless delete $args->{_noRegion};
	$args->{part}       ||= 'snippet' unless delete $args->{_noPart};
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
	
	main::INFOLOG && $log->info('Calling API: ' . $url);

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