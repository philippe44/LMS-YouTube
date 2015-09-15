package Plugins::YouTube::Plugin;

# Plugin to stream audio from YouTube videos streams
#
# Released under GPLv2

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Data::Dumper;
use Encode qw(encode decode);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::YouTube::API;
use Plugins::YouTube::ProtocolHandler;
use Plugins::YouTube::ListProtocolHandler;

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

$prefs->init({ 
	prefer_lowbitrate => 0, 
	recent => [], 
	APIkey => '', 
	max_items => 200, 
	country => setCountry(),
	cache => 1
});

tie my %recentlyPlayed, 'Tie::Cache::LRU', 50;

sub setCountry {
	my $convert = { EN => 'US', FR => 'FR' };
	my $lang = Slim::Utils::Strings::getLanguage();
	
	$lang = $convert->{$lang} if $convert->{$lang};
	
	return $lang;
}

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
	
#        |requires Client
#        |  |is a Query
#        |  |  |has Tags
#        |  |  |  |Function to call
	Slim::Control::Request::addDispatch(['youtube', 'info'], 
		[1, 1, 1, \&cliInfoQuery]);

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
	
	if (!Slim::Networking::Async::HTTP::hasSSL()) {
		$callback->([
			{ name => cstring($client, 'PLUGIN_YOUTUBE_MISSINGSSL'), type => 'text' },
		]);
		return;
	}
	
	$callback->([
		{ name => cstring($client, 'PLUGIN_YOUTUBE_VIDEOCATEGORIES'), type => 'url', url => \&videoCategoriesHandler },
		
		{ name => cstring($client, 'PLUGIN_YOUTUBE_GUIDECATEGORIES'), type => 'url', url => \&guideCategoriesHandler },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_SEARCH'),  type => 'search', url => \&searchHandler },

		#FIXME: is this always 10 ?
		{ name => cstring($client, 'PLUGIN_YOUTUBE_MUSICSEARCH'), type => 'search', url => \&searchHandler, passthrough => [ { videoCategoryId => 10 } ] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_CHANNELSEARCH'), type => 'search', url => \&searchHandler, passthrough => [ { type => 'channel' } ] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_PLAYLISTSEARCH'), type => 'search', url => \&searchHandler, passthrough => [ { type => 'playlist' } ] },
		
		{ name => cstring($client, 'PLUGIN_YOUTUBE_WHOLE'), type => 'search', url => \&searchHandler, passthrough => [ { type => 'video,channel,playlist' } ] },
	
		{ name => cstring($client, 'PLUGIN_YOUTUBE_RECENTLYPLAYED'), url  => \&recentHandler, },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_URL'), type => 'search', url  => \&urlHandler, },
	]);
}

sub urlHandler {
	my ($client, $cb, $args) = @_;
	
	my $url = $args->{search};

	# because search replaces '.' by ' '
	$url =~ s/ /./g;
	
	my $id = Plugins::YouTube::ProtocolHandler->getId($url);
	
	my $errorItems = { items => [ { 
		type => 'text',
		name => cstring($client, 'PLUGIN_YOUTUBE_BADURL'), 
	} ] };
	
	if (!$id) {
		$cb->( $errorItems );
		return;
	}
				
	Plugins::YouTube::API->getVideoDetails( sub {
		my $items = $_[0]->{items};
		
		if (scalar @$items) {
			$cb->( _renderList($items) );
		}
		else {
			$cb->( $errorItems );
		}
	}, $id );
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

sub guideCategoriesHandler {
	my ($client, $cb, $args) = @_;
	
	Plugins::YouTube::API->getGuideCategories(sub {
		my $result = shift;
		
		my $items = [];

		for my $entry (@{$result->{items} || []}) {
			my $title = $entry->{snippet}->{title} || next;

			push @$items, {
				name => $title,
				type => 'url',
				url  => \&channelHandler,
				passthrough => [  { categoryId => $entry->{id} } ],
			};
		}

		$cb->( $items );
	}, $args->{quantity} + $args->{index} || 0 );
}

sub videoCategoriesHandler {
	my ($client, $cb, $args) = @_;
	
	Plugins::YouTube::API->getVideoCategories(sub {
		my $result = shift;
		
		my $items = [];

		for my $entry (@{$result->{items} || []}) {
			my $title = $entry->{snippet}->{title} || next;

			push @$items, {
				name => $title,
				type => 'search',
				url  => \&searchHandler,
				passthrough => [  { videoCategoryId => $entry->{id} } ],
			};
		}

		$cb->( $items );
	}, $args->{quantity} + $args->{index} || 0 );
}

sub searchHandler {
	my ($client, $cb, $args, $params) = @_;
	
	if ($args->{search}) {
		$args->{search} = encode('utf8', $args->{search});
		$params->{q} ||= delete $args->{search};
	}	
	
	$params->{quota} = defined $args->{index} ? 
					   ($args->{index} eq '') ? undef : $args->{quantity} + $args->{index} :
					   $args->{quantity};
	
	Plugins::YouTube::API->search(sub {
		$cb->( { items => _renderList($_[0]->{items}), 
				 total => $_[0]->{total} } );
	}, $params );
}

sub playlistHandler {
	my ($client, $cb, $args, $params) = @_;
	
	$params ||= {};
	
	Plugins::YouTube::API->searchDirect('playlistItems', sub {
		$cb->( { items => _renderList($_[0]->{items}), 
				 total => $_[0]->{total} } );
	}, {
		playlistId 	=> $params->{playlistId},
		quota  => defined $args->{index} ? 
				($args->{index} eq '') ? undef : $args->{quantity} + $args->{index} :
				$args->{quantity},
	});
}

sub channelHandler {
	my ($client, $cb, $args, $params) = @_;
	
	$params ||= {};
	
	Plugins::YouTube::API->searchDirect('channels', sub {
		$cb->( { items => _renderList($_[0]->{items}), 
				 total => $_[0]->{total} } );
	}, {
		quota  => defined $args->{index} ? 
				($args->{index} eq '') ? undef : $args->{quantity} + $args->{index} :
				$args->{quantity},
		%{$params},
	});
}

sub _renderList {
	my ($entries, $through) = @_;
	my $items = [];
	
	$through ||= {};
	
	for my $entry (@{$entries || []}) {
		my $snippet = $entry->{snippet} || next;
		my $title = $snippet->{title} || next;
		
		next unless $entry->{id};
		
		my $item = {
			name => $title,
			type => 'playlist',
			image => _getImage($snippet->{thumbnails}),
		};
		
		# result of search amongst guided channels (search for video or playlist) 
		if ($entry->{kind} eq 'youtube#channel') {
			my $id = $entry->{id};
						
			$item->{passthrough} = [ { channelId => $id, type => 'video,playlist' } ];
			$item->{url}        = \&searchHandler;
			#$item->{type}		= 'search';
			$item->{favorites_url}	= 'ytplaylist://channelId=' . $id;
			$item->{favorites_type}	= 'audio';
		}
		#result of search amongst videos within a given channel/playlist
		elsif (!ref $entry->{id} || ($entry->{id}->{kind} && $entry->{id}->{kind} eq 'youtube#video')) {
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
		#result of search amongst channels
		elsif (my $id = $entry->{id}->{channelId}) {
			$item->{name} = '<b>(C)</b> ' . $title;
			$item->{passthrough} = [ { channelId => $id, %{$through} } ];
			$item->{url}         = \&searchHandler;
			$item->{favorites_url}	= 'ytplaylist://channelId=' . $id;
			$item->{favorites_type}	= 'audio';
		}
		#result of search amongst playlists
		elsif (my $id = $entry->{id}->{playlistId}) {
			$item->{name} = '<b>(P)</b> ' . $title;
			$item->{passthrough} = [ { playlistId => $id, %{$through} } ];
			$item->{url}         = \&playlistHandler;
			$item->{favorites_url}	= 'ytplaylist://playlistId=' . $id;
			$item->{favorites_type}	= 'audio';
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
		foreach ( qw(default maxres standard high medium) ) {
			last if $image = $thumbs->{$_}->{url};
		}
	}
	
	return $image;
}

sub trackInfoMenu {
	my ($client, $url, $track, $remoteMeta) = @_;

	my $artist = ($remoteMeta && $remoteMeta->{artist}) || ($track && $track->artistName) || '';
	my $title  = ($remoteMeta && $remoteMeta->{title}) || ($track && $track->title) || '';

	if ($artist || $title) {
		return {
			type      => 'outline',
			name      => cstring($client, 'PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => \&searchHandler,
			passthrough => [ { q => "$artist $title" } ], 
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
			url       => \&searchHandler,
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
				url  => \&searchHandler, 
				passthrough => [ { q => $query }]
			},
			{
				name => cstring($client, 'PLUGIN_YOUTUBE_MUSICSEARCH'),
				type => 'link',
				url  => \&searchHandler, 
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
