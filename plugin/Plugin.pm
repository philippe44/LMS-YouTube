package Plugins::YouTube::Plugin;

# Plugin to stream audio from YouTube videos streams
#
# Released under GPLv2

use strict;
use base qw(Slim::Plugin::OPMLBased);

use URI::Escape;
use JSON::XS;
use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);
use Data::Dumper;

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::YouTube::API;
use Plugins::YouTube::ProtocolHandler;

use constant BASE_URL => 'www.youtube.com/v/';
use constant STREAM_BASE_URL => 'youtube://' . BASE_URL;

my	$log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.youtube',
	'defaultLevel' => 'WARN',
	'description'  => string('PLUGIN_YOUTUBE'),
});

my $prefs = preferences('plugin.youtube');

$prefs->init({ prefer_lowbitrate => 0, recent => [], APIkey => '', max_items => 500, country => Slim::Utils::Strings::getLanguage(), APIurl => 'https://www.googleapis.com/youtube/v3' });

tie my %recentlyPlayed, 'Tie::Cache::LRU', 20;

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'youtube',
		menu   => 'radios',
		is_app => 1,
		weight => 10,
	);

	Slim::Menu::TrackInfo->registerInfoProvider( youtube => (
		after => 'middle',
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( youtubevideo => (
		after => 'bottom',
		func  => \&webVideoLink,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( youtube => (
		after => 'middle',
		func  => \&artistInfoMenu,
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( youtube => (
		after => 'middle',
		name  => 'PLUGIN_YOUTUBE',
		func  => \&searchInfoMenu,
	) );

	if ( main::WEBUI ) {
		require Plugins::YouTube::Settings;
		Plugins::YouTube::Settings->new;
	}

	for my $recent (reverse @{$prefs->get('recent')}) {
		$recentlyPlayed{ $recent->{'url'} } = $recent;
	}

	Slim::Control::Request::addDispatch(['youtube', 'info'], [1, 1, 1, \&cliInfoQuery]);
}

sub shutdownPlugin {
	my $class = shift;

	$class->saveRecentlyPlayed('now');
}

sub getDisplayName { 'PLUGIN_YOUTUBE' }

sub updateRecentlyPlayed {
	my ($class, $info) = @_;

	$recentlyPlayed{ $info->{'url'} } = $info;

	$class->saveRecentlyPlayed;
}

sub saveRecentlyPlayed {
	my $class = shift;
	my $now   = shift;

	unless ($now) {
		Slim::Utils::Timers::killTimers($class, \&saveRecentlyPlayed);
		Slim::Utils::Timers::setTimer($class, time() + 10, \&saveRecentlyPlayed, 'now');
		return;
	}

	my @played;

	for my $key (reverse keys %recentlyPlayed) {
		unshift @played, $recentlyPlayed{ $key };
	}

	$prefs->set('recent', \@played);
}

sub toplevel {
	my ($client, $callback, $args) = @_;
	
	if (!$prefs->get('APIkey')) {
		$callback->([
			{ name => string('PLUGIN_YOUTUBE_MISSINGKEY'), type => 'text' },
		]);
			return;
	}
	
	$callback->([
	  
		{ name => string('PLUGIN_YOUTUBE_VIDEOCATEGORIES'), type => 'url', url => \&videoCategoriesHandler },

		{ name => string('PLUGIN_YOUTUBE_SEARCH'),  type => 'search', url => \&videoSearchHandler },

		#FIXME: is this always 10 ?
		{ name => string('PLUGIN_YOUTUBE_MUSICSEARCH'), type => 'search', url => \&videoSearchHandler, passthrough => [ { videoCategoryId => 10 }] },

		{ name => string('PLUGIN_YOUTUBE_CHANNELSEARCH'), type => 'search', url => \&channelSearchHandler },

		{ name => string('PLUGIN_YOUTUBE_PLAYLISTSEARCH'), type => 'search', url => \&playlistSearchHandler },
	
		{ name => string('PLUGIN_YOUTUBE_RECENTLYPLAYED'), url  => \&recentHandler, },

		{ name => string('PLUGIN_YOUTUBE_URL'), type => 'search', url  => \&urlHandler, },
	]);
}

sub urlHandler {
	my ($client, $cb, $args) = @_;
	
	my $url = $args->{search};

	# because search replaces '.' by ' '
	$url =~ s/ /./g;
				
	Plugins::YouTube::API->getVideoDetails( sub {
		$cb->( _renderList($_[0]->{items}) );
	}, Plugins::YouTube::ProtocolHandler->getId($url) );
}

sub recentHandler {
	my ($client, $callback, $args) = @_;

	my @menu;

	for my $item(reverse values %recentlyPlayed) {
		unshift  @menu, {
			name => $item->{'name'},
			play => $item->{'url'},
			on_select => 'play',
			image => $item->{'icon'},
			type => 'playlist',
		};
	}

	$callback->({ items => \@menu });
}

sub videoCategoriesHandler {
	my ($client, $cb) = @_;
	
	Plugins::YouTube::API->getVideoCategories(sub {
		my $result = shift;
		
		my $items = [];

		for my $entry (@{$result->{items} || []}) {
			my $title = $entry->{snippet}->{title} || next;

			push @$items, {
				name => $title,
				type => 'search',
				url  => \&videoSearchHandler,
				passthrough => [  { videoCategoryId => $entry->{id} } ],
			};
		}

		$cb->( $items );
	});
}

sub videoSearchHandler {
	my ($client, $cb, $args, $params) = @_;
	
	$params->{q} ||= delete $args->{search} if $args->{search};
	
	Plugins::YouTube::API->searchVideos(sub {
		$cb->( _renderList($_[0]->{items}) );
	}, $params);
}

sub channelSearchHandler {
	my ($client, $cb, $args) = @_;
	
	Plugins::YouTube::API->searchChannels(sub {
		$cb->( _renderList($_[0]->{items}) );
	},{
		q => delete $args->{search}
	});
}

sub playlistSearchHandler {
	my ($client, $cb, $args) = @_;
	
	Plugins::YouTube::API->searchPlaylists(sub {
		$cb->( _renderList($_[0]->{items}) );
	}, {
		q => delete $args->{search}
	});
}

sub _renderList {
	my ($entries) = @_;

	my $items = [];

	for my $entry (@{$entries || []}) {
		my $snippet = $entry->{snippet} || next;
		my $title = $snippet->{title} || next;
		
		next unless $entry->{id};
		
		my $item = {
			name => $title,
			type => 'playlist',
			image => _getImage($snippet->{thumbnails}),
		};

		if (!ref $entry->{id} || ($entry->{id}->{kind} && $entry->{id}->{kind} eq 'youtube#video')) {
			my $id;

			if ($snippet->{id}) {
				$id = $snippet->{id}->{videoId};
			}
			elsif ($snippet->{resourceId}) {
				$id = $snippet->{resourceId}->{videoId}
			}
			elsif (!ref $entry->{id}) {
				$id = $entry->{id};
			}
			elsif ($entry->{id}->{videoId}) {
				$id = $entry->{id}->{videoId};
			}
			
			if (!$id) {
				$log->error("Unexpected data: " . Data::Dump::dump($entry));
				next;
			}
			
			my $url = STREAM_BASE_URL . $id;

			$item->{on_select} = 'play';
			$item->{play}      = $url;
		}
		elsif (my $id = $entry->{id}->{channelId}) {
			$item->{passthrough} = [ { channelId => $id } ];
			$item->{url}         = \&videoSearchHandler;
		}
		elsif (my $id = $entry->{id}->{playlistId}) {
			$item->{passthrough} = [ { playlistId => $id } ];
			$item->{url}         = \&playlistHandler;
		}
		else {
			# no known item type - skip it
			$log->warn("Unknown item type");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($entry));
			next;
		}

		push @$items, $item;
	}
	
	return $items;
}

sub _getImage {
	my ($imageList) = @_;
	
	my $image;
	
	if (my $thumbs = $imageList) {
		foreach ( qw(maxres standard high medium default) ) {
			last if $image = $thumbs->{$_}->{url};
		}
	}
	
	return $image;
}

sub playlistHandler {
	my ($client, $cb, $args, $params) = @_;
	
	Plugins::YouTube::API->getPlaylist(sub {
		$cb->( _renderList($_[0]->{items}) );
	}, {
		playlistId => $params->{playlistId}
	});
}

sub searchHandler {
	my ($client, $callback, $args, $feed, $parser, $term) = @_;
	my $menu = [];

	# use paging on interfaces which allow otherwise fetch 200 entries for button mode
	my $index    = $args->{'index'} || 0;
	my $quantity = $args->{'quantity'} || 200;
	my $search   = $args->{'search'} ? "$args->{search}" : '';
	my $next;
	my $count = 0;
			
	$term ||= '';	
	$search = URI::Escape::uri_escape_utf8($search);
	$search = "q=$search";
	
	$log->debug("search: $search, feed: $feed, parser :$parser, term: $term\n", Dumper($args));
		
	# fetch in stages as api only allows 50 items per response, cli clients require $quantity responses which can be more than 50
	my $fetch;

	# FIXME: this could be sped up by performing parallel requests once the number of responses is known??
	$fetch = sub {

		my $max = 50;
		my $queryUrl;

		if ($feed =~ /^http/) {
			$queryUrl = "$feed&pageToken=$next&maxResults=$max&v=2&alt=json";
		} else {
		
			##$queryUrl = "http://gdata.youtube.com/feeds/api/$feed?$term&$search&start-index=$i&max-results=$max&v=2&alt=json";
			$queryUrl = $prefs->get('APIurl') . "/search/?$search";
			
			if ($feed =~ /(channel|playlist)/) {
				$queryUrl .="&type=$1"; 
			} elsif ($feed =~ /(videos)/) {
				# nothing now
			} elsif ($feed =~ /(guideCategories)/) {
			   $queryUrl = $prefs->get('APIurl') . "/$1?regionCode=". $prefs->get('country');
			}
			
			if ($term) {
				$queryUrl .= "&$term";
			}
			
			$queryUrl .= "&pageToken=$next&maxResults=$max&v=2&alt=json&part=id,snippet&key=" . $prefs->get('APIkey');
			
		}

		$log->info("fetching: $queryUrl");
		_debug('queryUrl',$feed,$queryUrl);
		
		Slim::Networking::SimpleAsyncHTTP->new(

			sub {
				my $http = shift;
				
				my $json = eval { decode_json($http->content) };
				
				if ($@) {
					$log->warn($@);
				}

				# Restrict responses to requested searchmax 
				my $total = min($json->{'pageInfo'}->{'totalResults'}, $args->{'searchmax'} || $prefs->get('max_items'), $prefs->get('max_items'));
				my $n = $json->{'pageInfo'}->{'resultsPerPage'};
				
				# The 'categories' search do not have a totalResults / resultsPerPage
				if (!$total) {
					$n = $total = scalar @{$json->{'items'}} || 0;
				}
				
				$count += $n;
				$parser->($json, $menu);
				$log->debug("this page: " . scalar @$menu . " index: $index" . " quantity: $quantity" . " count: $count" . " total: $total" . " next: $next");

				# get some more if we have yet to build the required page for client				
				if ($total && (scalar @$menu < $quantity + $index) && ($count < $total)) {
					$next = $json->{'nextPageToken'};
					$log->debug("fetching recursive");
					$fetch->();

				} else {

					$callback->({
						items  => $menu,
						offset => 0,
						total  => $total,
					});
				}
			},

			sub {
				$log->warn("error: $_[1] ");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},

		)->get($queryUrl);
	};

	$fetch->();
}


sub _parseVideos {
	my ($json, $menu) = @_;
	for my $entry (@{$json->{'items'} || []}) {
		my $vurl = "www.youtube.com/v/$entry->{id}->{videoId}";
		#$log->debug("parse video (url: $vurl) ==> " , Dumper($entry));
		$log->debug("parse video (url: $vurl)");
		push @$menu, {
			name => $entry->{'snippet'}->{'title'},
			type => 'audio',
			on_select => 'play',
			playall => 0,
			url  => 'youtube://' . $vurl,
			play => 'youtube://' . $vurl,
			icon => $entry->{'snippet'}->{'thumbnails'}->{'default'}->{'url'},
		};
	}
}


sub _parseVideosAlternate {
	my ($json, $menu) = @_;
	for my $entry (@{$json->{'items'} || []}) {
		my $vurl = "www.youtube.com/v/$entry->{'snippet'}->{resourceId}->{videoId}";
		#$log->debug("parse video alternate (url: $vurl) ==> " , Dumper($entry));
		$log->debug("parse video alternate (url: $vurl)");
		push @$menu, {
			name => $entry->{'snippet'}->{'title'},
			type => 'audio',
			on_select => 'play',
			playall => 0,
			url  => 'youtube://' . $vurl,
			play => 'youtube://' . $vurl,
			icon => $entry->{'snippet'}->{'thumbnails'}->{'default'}->{'url'},
		};
	}
}

sub _debug{
	$log->debug(Dumper([caller,@_]));
}

sub trackInfoMenu {
	my ($client, $url, $track, $remoteMeta) = @_;

	my $artist = ($remoteMeta && $remoteMeta->{artist}) || ($track && $track->artistName);

	$artist = URI::Escape::uri_escape_utf8($artist);

	if ($artist) {
		return {
			type      => 'opml',
			name      => string('PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => sub {
				my ($client, $callback, $args) = @_;
				$args->{'search'} = $artist;
				$args->{'searchmax'} = 200; # only get 200 entries within context menu
				searchHandler($client, $callback, $args, 'videos', \&_parseVideos);
			},
			favorites => 0,
		};
	} else {
		return {};
	}
}

sub artistInfoMenu {
	my ($client, $url, $obj, $remoteMeta) = @_;

	my $artist = ($remoteMeta && $remoteMeta->{artist}) || ($obj && $obj->name);

	$artist = URI::Escape::uri_escape_utf8($artist);

	if ($artist) {
		return {
			type      => 'opml',
			name      => string('PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => sub {
				my ($client, $callback, $args) = @_;
				$args->{'search'} = $artist;
				$args->{'searchmax'} = 200; # only get 200 entries within context menu
				searchHandler($client, $callback, $args, 'videos', \&_parseVideos);
			},
			favorites => 0,
		};
	} else {
		return {};
	}
}

sub webVideoLink {
	my ($client, $url) = @_;

#	_debug('webVideoLink',$url);
	
	if (my $id = Plugins::YouTube::ProtocolHandler->getId($url)) {

		my $show;
		my $i = 0;
		while (my $caller = (caller($i++))[3]) {
			if ($caller =~ /Slim::Web::Pages/) {
				$show = 1;
				last;
			}
			if ($caller =~ /cliQuery/) {
				if ($client->can('controllerUA') && $client->controllerUA =~ /iPeng/) {
					$show = 1;
				}
				last;
			}
		}

		if ($show) {
			return {
				type    => 'text',
				name    => string('PLUGIN_YOUTUBE_WEBLINK'),
				weblink => "http://www.youtube.com/watch?v=$id",
				jive => {
					actions => {
						go => {
							cmd => [ 'youtube', 'info' ],
							params => {
								id => $id,
							},
						},
					},
				},
			};
		}
	}

	return undef;
}

sub searchInfoMenu {
	my ($client, $tags) = @_;

	my $query = $tags->{'search'};

	$query = URI::Escape::uri_escape_utf8($query);

	return {
		name => string('PLUGIN_YOUTUBE'),
		items => [
			{
				name => string('PLUGIN_YOUTUBE_SEARCH'),
				type => 'link',
				url  => sub {
					my ($client, $callback, $args) = @_;
					$args->{'search'} = $query;
					searchHandler($client, $callback, $args, 'videos', \&_parseVideos);
				},
				favorites => 0,
			},
			{
				name => string('PLUGIN_YOUTUBE_MUSICSEARCH'),
				type => 'link',
				url  => sub {
					my ($client, $callback, $args) = @_;
					$args->{'search'} = $query;
					#FIXME: is this always 10 ?
					searchHandler($client, $callback, $args, 'videos', \&_parseVideos, 'type=video&videoCategoryId=10');
				},
				favorites => 0,
			},
		   ],
	};
}

# special query to allow weblink to be sent to iPeng
sub cliInfoQuery {
	my $request = shift;

	if ($request->isNotQuery([['youtube'], ['info']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $id = $request->getParam('id');

	$request->addResultLoop('item_loop', 0, 'text', string('PLUGIN_YOUTUBE_PLAYLINK'));
	$request->addResultLoop('item_loop', 0, 'weblink', "http://www.youtube.com/v/$id");
	$request->addResult('count', 1);
	$request->addResult('offset', 0);

	$request->setStatusDone();
}

1;
