package Plugins::YouTube::Plugin;

# Plugin to stream audio from YouTube videos streams
#
# Released under GPLv2

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::YouTube::API;
use Plugins::YouTube::ProtocolHandler;

use constant BASE_URL => 'www.youtube.com/v/';
use constant STREAM_BASE_URL => 'youtube://' . BASE_URL;
use constant VIDEO_BASE_URL  => 'http://www.youtube.com/watch?v=%s';

my $WEBLINK_SUPPORTED_UA_RE = qr/iPeng|SqueezePad|OrangeSqueeze/i;


my	$log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.youtube',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_YOUTUBE',
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
			{ name => cstring($client, 'PLUGIN_YOUTUBE_MISSINGKEY'), type => 'text' },
		]);
		return;
	}
	
	$callback->([
		{ name => cstring($client, 'PLUGIN_YOUTUBE_VIDEOCATEGORIES'), type => 'url', url => \&videoCategoriesHandler },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_SEARCH'),  type => 'search', url => \&videoSearchHandler },

		#FIXME: is this always 10 ?
		{ name => cstring($client, 'PLUGIN_YOUTUBE_MUSICSEARCH'), type => 'search', url => \&videoSearchHandler, passthrough => [ { videoCategoryId => 10 }] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_CHANNELSEARCH'), type => 'search', url => \&channelSearchHandler },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_PLAYLISTSEARCH'), type => 'search', url => \&playlistSearchHandler },
	
		{ name => cstring($client, 'PLUGIN_YOUTUBE_RECENTLYPLAYED'), url  => \&recentHandler, },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_URL'), type => 'search', url  => \&urlHandler, },
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

sub trackInfoMenu {
	my ($client, $url, $track, $remoteMeta) = @_;

	# XXX - should we search for track title, too?
	my $artist = ($remoteMeta && $remoteMeta->{artist}) || ($track && $track->artistName);

	if ($artist) {
		return {
			type      => 'outline',
			name      => cstring($client, 'PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => \&videoSearchHandler,
			passthrough => [ { q => $artist } ], 
		};
	}
}

sub artistInfoMenu {
	my ($client, $url, $obj, $remoteMeta) = @_;

	my $artist = ($remoteMeta && $remoteMeta->{artist}) || ($obj && $obj->name);

	if ($artist) {
		return {
			type      => 'outline',
			name      => cstring($client, 'PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => \&videoSearchHandler,
			passthrough => [ { q => $artist } ], 
		};
	}
}

sub webVideoLink {
	my ($client, $url, $obj, $remoteMeta, $tags, $filter) = @_;
	
	return unless $client;

	if (my $id = Plugins::YouTube::ProtocolHandler->getId($url)) {

		# only web UI (controllerUA undefined) and certain controllers allow watching videos
		if ( ($client->controllerUA && $client->controllerUA =~ $WEBLINK_SUPPORTED_UA_RE) || not defined $client->controllerUA ) {
			return {
				type    => 'text',
				name    => cstring($client, 'PLUGIN_YOUTUBE_WEBLINK'),
				weblink => sprintf(VIDEO_BASE_URL, $id),
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
}

sub searchInfoMenu {
	my ($client, $tags) = @_;

	my $query = $tags->{'search'};

	return {
		name => cstring($client, 'PLUGIN_YOUTUBE'),
		items => [
			{
				name => cstring($client, 'PLUGIN_YOUTUBE_SEARCH'),
				type => 'link',
				url  => \&videoSearchHandler, 
				passthrough => [ { q => $query }]
			},
			{
				name => cstring($client, 'PLUGIN_YOUTUBE_MUSICSEARCH'),
				type => 'link',
				url  => \&videoSearchHandler, 
				passthrough => [ { videoCategoryId => 10, q => $query }]
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

	$request->addResultLoop('item_loop', 0, 'text', cstring($request->client, 'PLUGIN_YOUTUBE_PLAYLINK'));
	$request->addResultLoop('item_loop', 0, 'weblink', sprintf(VIDEO_BASE_URL, $id));
	$request->addResult('count', 1);
	$request->addResult('offset', 0);

	$request->setStatusDone();
}

1;
