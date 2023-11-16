package Plugins::YouTube::Plugin;

# Plugin to stream audio from YouTube videos streams
#
# Released under GPLv2

use strict;
use base qw(Slim::Plugin::OPMLBased);

use List::Util qw(first);
use Encode qw(encode decode);
use JSON::XS::VersionOneAndTwo;
use HTML::Entities;

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Cache;

use Plugins::YouTube::API;
use Plugins::YouTube::ProtocolHandler;
use Plugins::YouTube::ListProtocolHandler;
use Plugins::YouTube::Oauth2;

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
my $cache = Slim::Utils::Cache->new();

$prefs->init({
	prefer_lowbitrate => 0,
	recent => [],
	APIkey => '',
	max_items => 200,
	country => setCountry(),
	cache => 1,
	highres_icons => 1,
	live_delay => 60,
	live_edge => 1,
	aac => 1,
	ogg => 1,
	cache_ttl => 300,
});

tie my %recentlyPlayed, 'Tie::Cache::LRU', 50;
my $convertCountry = { EN => 'US', CS => 'CZ' };

sub setCountry {
	my $lang = substr(Slim::Utils::Strings::getLanguage(), -2);
	return $convertCountry->{$lang} || $lang;
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

	Slim::Menu::AlbumInfo->registerInfoProvider( youtube => (
		after => 'middle',
		func  => \&albumInfoMenu,
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

	%recentlyPlayed = map { $_->{url} => $_ } reverse @{$prefs->get('recent')};

	$prefs->set('country', $convertCountry->{$prefs->get('country')}) if $convertCountry->{$prefs->get('country')};

#        |requires Client
#        |  |is a Query
#        |  |  |has Tags
#        |  |  |  |Function to call
	Slim::Control::Request::addDispatch(['youtube', 'info'],
		[1, 1, 1, \&cliInfoQuery]);
}

sub shutdownPlugin {
	my @played = values %recentlyPlayed;
	$prefs->set('recent', \@played);
}

sub getDisplayName { 'PLUGIN_YOUTUBE' }

sub updateRecentlyPlayed {
	my ($class, $info) = @_;
	$recentlyPlayed{ $info->{'url'} } ||= $info;
}

sub toplevel {
	my ($client, $callback, $args) = @_;

=comment
	if (!$prefs->get('APIkey')) {
		$callback->([
			{ name => cstring($client, 'PLUGIN_YOUTUBE_MISSINGKEY'), type => 'textarea' },
		]);
		return;
	}
=cut    

	if (!Slim::Networking::Async::HTTP::hasSSL() || !eval { require IO::Socket::SSL } ) {
		$callback->([
			{ name => cstring($client, 'PLUGIN_YOUTUBE_MISSINGSSL'), type => 'text' },
		]);
		return;
	}

	$callback->([
		{ name => cstring($client, 'PLUGIN_YOUTUBE_VIDEOCATEGORIES'), type => 'url', url => \&videoCategoriesHandler },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_GUIDECATEGORIES'), type => 'url', url => \&guideCategoriesHandler },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_VIDEOSEARCH'),  type => 'search', url => \&searchHandler },

		#FIXME: is this always 10 ?
		{ name => cstring($client, 'PLUGIN_YOUTUBE_MUSICSEARCH'), type => 'search', url => \&searchHandler, passthrough => [ { videoCategoryId => 10 } ] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_CHANNELSEARCH'), type => 'search', url => \&searchHandler, passthrough => [ { type => 'channel' } ] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_PLAYLISTSEARCH'), type => 'search', url => \&searchHandler, passthrough => [ { type => 'playlist' } ] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_WHOLE'), type => 'search', url => \&searchHandler, passthrough => [ { type => 'video,channel,playlist' } ] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_URL'), type => 'search', url  => \&urlHandler, },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_URLRELATEDSEARCH'), type => 'search', url => \&relatedURLHandler },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_PLAYLISTID'), type => 'search', url  => \&playlistIdHandler, },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_CHANNELID'), type => 'search', url  => \&channelIdHandler, passthrough => [ { type => 'playlist,video' } ]},

		{ name => cstring($client, 'PLUGIN_YOUTUBE_CHANNELIDPLAYLIST'), type => 'search', url  => \&channelIdHandler, passthrough => [ { type => 'playlist' } ]},

		{ name => cstring($client, 'PLUGIN_YOUTUBE_LIVEVIDEOSEARCH'),  type => 'search', url => \&searchHandler, passthrough => [ { eventType => 'live' } ] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_MYSUBSCRIPTIONS'), type => 'url', url => \&subscriptionsHandler, passthrough => [ { count => 2 } ] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_MYPLAYLISTS'), type => 'url', url => \&myPlaylistHandler, passthrough => [ { count => 2 } ] },

		{ name => cstring($client, 'PLUGIN_YOUTUBE_RECENTLYPLAYED'), url  => \&recentHandler, },
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
		if (scalar @{$_[0]->{items}}) {
			$cb->( _renderList($_[0]) );
		}
		else {
			$cb->( $errorItems );
		}
	}, $id );
}


sub relatedURLHandler {
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

	Plugins::YouTube::API->search(sub {
		$cb->( _renderList($_[0]) );
	}, 	{
		type 			 => 'video',
		relatedToVideoId => $id,
		_index 			 => $args->{index},
		_quantity 		 => $args->{quantity},
	});
}


sub playlistIdHandler {
	my ($client, $cb, $args) = @_;
	my $url = $args->{search};

	# because search replaces '.' by ' '
	$url =~ s/ /./g;
	my ($id) = $url =~ /list=([^&]+)/;
	$id ||= $url;

	if (!$id) {
		$cb->( { items => [ {
			type => 'text',
			name => cstring($client, 'PLUGIN_YOUTUBE_BADURL'),
			} ] } );
		return;
	}

	Plugins::YouTube::API->searchDirect( 'playlistItems', sub {
			$cb->( _renderList($_[0]) );
	},{
		_index  	=> $args->{index},
		_quantity 	=> $args->{quantity},
		playlistId  => $id ,
	});
}


sub recentHandler {
	my ($client, $callback, $args) = @_;

	my @menu;

	for my $item(reverse values %recentlyPlayed) {
		my $id = Plugins::YouTube::ProtocolHandler->getId($item->{'url'});
		if ((my $lastpos = $cache->get("yt:lastpos-$id")) && $args && length $args->{index}) {
			my $position = Slim::Utils::DateTime::timeFormat($lastpos);
			$position =~ s/^0+[:\.]//;
			unshift @menu, {
				type => "link",
				image => $item->{'icon'},
				name => $item->{'name'},
				items => [ {
						title => cstring(undef, 'PLUGIN_YOUTUBE_PLAY_FROM_BEGINNING'),
						type   => 'audio',
						url    => $item->{url},
					}, {
						title => cstring(undef, 'PLUGIN_YOUTUBE_PLAY_FROM_POSITION_X', $position),
						type   => 'audio',
						url    => $item->{url} . "&lastpos=$lastpos",
					} ],
			};
		} else {
			unshift  @menu, {
				name => $item->{'name'},
				play => $item->{'url'},
				on_select => 'play',
				image => $item->{'icon'},
				type => 'playlist',
			};
		}
	}

	$callback->({ items => \@menu });
}

sub guideCategoriesHandler {
	my ($client, $cb, $args) = @_;

	Plugins::YouTube::API->getCategories('guideCategories', sub {
		my $result = shift;
		my @items;

		for my $entry (@{$result->{items} || []}) {
			my $title = $entry->{snippet}->{title} || next;

			push @items, {
				name => $title,
				type => 'url',
				url  => \&channelHandler,
				passthrough => [  { categoryId => $entry->{id} } ],
			};
		}

		$result->{items} = \@items;

		$cb->( $result );
	}, {
		_index	   => $args->{index},
		_quantity  => $args->{quantity},
	});
}

sub videoCategoriesHandler {
	my ($client, $cb, $args) = @_;

	Plugins::YouTube::API->getCategories('videoCategories', sub {
		my $result = shift;
		my @items;

		for my $entry (@{$result->{items} || []}) {
			my $title = $entry->{snippet}->{title} || next;

			push @items, {
				name => $title,
				type => 'search',
				url  => \&searchHandler,
				passthrough => [  { videoCategoryId => $entry->{id} } ],
			};
		}

		$result->{items} = \@items;

		$cb->( $result );
	}, {
		_index	   => $args->{index},
		_quantity  => $args->{quantity},
	});
}


sub subscriptionsHandler {
	my ($client, $cb, $args, $params) = @_;

	if ( !$prefs->get('client_id') || !$params->{count} ) {
		$cb->( [ { name => cstring($client, 'PLUGIN_YOUTUBE_MISSINGOAUTH'), type => 'text' } ] );;
		return;
	}

	if ( !$cache->get('yt:access_token') ) {
		$params->{count}--;
		Plugins::YouTube::Oauth2::getToken(\&subscriptionsHandler, @_);
		return;
	}

	delete $params->{count};

	Plugins::YouTube::API->searchDirect('subscriptions', sub {
		$cb->( _renderList($_[0]) );
	}, {
		_cache_ttl 		=> 60,
		_noKey			=> 1,
		_index  		=> $args->{index},
		_quantity		=> $args->{quantity},
		mine			=> 'true',
		access_token 	=> $cache->get('yt:access_token'),
		order			=> 'alphabetical',
	});
}


sub myPlaylistHandler {
	my ($client, $cb, $args, $params) = @_;

	if ( !$prefs->get('client_id') || !$params->{count} ) {
		$cb->( [ { name => cstring($client, 'PLUGIN_YOUTUBE_MISSINGOAUTH'), type => 'text' } ] );
		return;
	}

	if ( !$cache->get('yt:access_token') ) {
		$params->{count}--;
		Plugins::YouTube::Oauth2::getToken(\&myPlaylistHandler, @_);
		return;
	}

	delete $params->{count};

	# need to passthrough the personal account items
	my $personal = {
					_cache_ttl 		=> 60,
					_noKey			=> 1,
					mine			=> 'true',
					access_token 	=> $cache->get('yt:access_token'),
				};

	Plugins::YouTube::API->searchDirect('playlists', sub {
		$cb->( _renderList($_[0], $personal) );
	}, {
		%{$personal},
		_index  	=> $args->{index},
		_quantity 	=> $args->{quantity},
	});
}

sub searchHandler {
	my ($client, $cb, $args, $params) = @_;

	if ($args->{search}) {
		$args->{search} = encode('utf8', $args->{search});
		$params->{q} ||= delete $args->{search};
		$params->{order} = 'relevance';
	}

	# workaround due to XMLBrowser management of defeatTTP
	$cache->set("yt:search-$client", $params->{q}, 60) if defined $params->{q};
	$params->{q} = $cache->get("yt:search-$client");

	$params->{_index} = $args->{index};
	$params->{_quantity} = $args->{quantity};

	Plugins::YouTube::API->search(sub {
		$cb->( _renderList($_[0]) );
	}, $params );
}

sub searchChannelHandler {
	my ($client, $cb, $args, $params) = @_;

	$params->{_index} = $args->{index};
	$params->{_quantity} = $args->{quantity};

	# get video only first (default filter) because adding 'playlist' in 'type' does not return as many
	Plugins::YouTube::API->search(sub {
		my $result = $_[0];

		# then add playlist with a separated query
		if ( $result->{total} < $prefs->get('max_items') ) {
			$log->info("adding playlist search");
			Plugins::YouTube::API->searchDirect('playlists', sub {
				my $total = { total => $result->{total} + $_[0]->{total},
							  # should add $result->{total} if option #2 of API was chosen
							  offset => $_[0]->{offset},
							  items => [ @{$result->{items}}, @{$_[0]->{items}} ] };
				$cb->( _renderList($total) );
			}, {
				%{$params},
				_index 		=> $args->{index} > $result->{total} ? $args->{index} - $result->{total} : 0,
				_quantity 	=> ($args->{quantity} ? $args->{quantity} : $prefs->get('max_items')) - $result->{total},
			} );
		} else {
			$log->info("menu full, no playlist search");
			$cb->( _renderList($result) );
		}
	}, $params );
}

sub playlistHandler {
	my ($client, $cb, $args, $params) = @_;

	$params->{_index} = $args->{index};
	$params->{_quantity} = $args->{quantity};

	Plugins::YouTube::API->searchDirect('playlistItems', sub {
		$cb->( _renderList($_[0]) );
	}, $params);
}

sub channelHandler {
	my ($client, $cb, $args, $params) = @_;

	$params ||= {};

	Plugins::YouTube::API->searchDirect('channels', sub {
		$cb->( _renderList($_[0]) );
	}, {
		_index  => $args->{index},
		_quantity => $args->{quantity},
		%{$params},
	});
}

sub channelIdHandler {
	my ($client, $cb, $args, $params) = @_;
	my $url = $args->{search};

	# because search replaces '.' by ' '
	$url =~ s/ /./g;
	my ($id) = $url =~ /channel=([^&]+)/;
	$id ||= $url;

	if (!$id) {
		$cb->( { items => [ {
			type => 'text',
			name => cstring($client, 'PLUGIN_YOUTUBE_BADURL'),
			} ] } );
		return;
	}

	Plugins::YouTube::API->search( sub {
			$cb->( _renderList($_[0]) );
	},{
		_index  	=> $args->{index},
		_quantity 	=> $args->{quantity},
		channelId 	=> $id,
		order		=> 'date',
		%{$params},
	});
}

sub _renderList {
	my ($args, $through) = @_;
	my @items;
	my $id;
	my $kind;

	my $chTags	= { prefix => $prefs->get('channel_prefix'),
					suffix => $prefs->get('channel_suffix') };
	my $plTags	= { prefix => $prefs->get('playlist_prefix'),
					suffix => $prefs->get('playlist_suffix') };

	$through ||= {};

	for my $entry ( @{$args->{items} || []} ) {
		my $snippet = $entry->{snippet} || next;
		my $title = $snippet->{title} || next;
		$title = decode_entities($title);

		next unless $entry->{id};
		next unless $snippet->{thumbnails};
		next if $title =~ /^Private/;

		my $item = {
			name => $title,
			type => 'playlist',
			image => _getImage($snippet->{thumbnails}),
		};

		# what is the type of item
		if ( $entry->{kind} eq 'youtube#searchResult' ) {
			$id = $entry->{id}->{videoId} || $entry->{id}->{channelId} || $entry->{id}->{playlistId};
			$kind = $entry->{id}->{kind};
		} elsif ($entry->{kind} eq 'youtube#subscription' || $entry->{kind} eq 'youtube#playlistItem') {
			$id = $entry->{snippet}->{resourceId}->{videoId} || $entry->{snippet}->{resourceId}->{channelId} || $entry->{snippet}->{resourceId}->{playlistId};
			$kind = $entry->{snippet}->{resourceId}->{kind};
		} elsif ($entry->{kind} eq 'youtube#channel') {
			$id = $entry->{id};
			$kind = 'youtube#guidechannel';
		} elsif ($entry->{kind} eq 'youtube#playlist' || $entry->{kind} eq 'youtube#video') {
			$id = $entry->{id};
			$kind = $entry->{kind};
		}

		main::DEBUGLOG && $log->is_debug && $log->debug("id:$id, kind:$kind");

		if (!$id) {
			$log->error("Unexpected data: " . Data::Dump::dump($entry));
			next;
		}

		# now organize the item list
		if ($kind eq 'youtube#guidechannel') {
			$item->{name} = $chTags->{prefix} . $title . $chTags->{suffix};
			$item->{passthrough} = [ { channelId => $id, type => 'video,playlist' } ];
			$item->{url}        = \&searchHandler;
			$item->{favorites_url}	= 'ytplaylist://channelId=' . $id;
			$item->{favorites_type}	= 'audio';
		} elsif ($kind eq 'youtube#video') {
			# dont't set type to audio to have icons
			#$item->{type} 	   = 'audio';
			$item->{on_select} 	= 'play';
			$item->{play}      	= STREAM_BASE_URL . $id;
			$item->{playall}	= 1;
			$item->{duration}	= 'N/A';
			if (my $lastpos = $cache->get("yt:lastpos-$id")) {
				my $position = Slim::Utils::DateTime::timeFormat($lastpos);
				$position =~ s/^0+[:\.]//;
				$item->{type} = "link";
				$item->{items} = [ {
						title => cstring(undef, 'PLUGIN_YOUTUBE_PLAY_FROM_BEGINNING'),
						enclosure => {
							type   => 'audio',
							url    => STREAM_BASE_URL . $id,
						},
						#duration => 'N/A',
					}, {
						title => cstring(undef, 'PLUGIN_YOUTUBE_PLAY_FROM_POSITION_X', $position),
						enclosure => {
							type   => 'audio',
							url    => STREAM_BASE_URL . $id . "&lastpos=$lastpos",
						}
						#duration => 'N/A',
				} ];
			}
		} elsif ($kind eq 'youtube#playlist') {
			$item->{name} = $plTags->{prefix} . $title . $plTags->{suffix};
			$item->{passthrough} = [ { playlistId => $id, _cache_ttl => $prefs->get('cache_ttl'), %{$through} } ];
			$item->{url}         = \&playlistHandler;
			$item->{favorites_url}	= 'ytplaylist://playlistId=' . $id;
			$item->{favorites_type}	= 'playlist';
		} elsif ($kind eq 'youtube#channel') {
			$item->{name} = $chTags->{prefix} . $title . $chTags->{suffix};
			$item->{passthrough} = [ { channelId => $id, _cache_ttl => $prefs->get('cache_ttl'), %{$through} } ];
			$item->{url}         = \&searchChannelHandler;
			$item->{favorites_url}	= 'ytplaylist://channelId=' . $id;
			$item->{favorites_type}	= 'playlist';
		} else {
			$log->warn("Unknown item type");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($entry));
			next;
		}

		push @items, $item;
	}

	$args->{items} = \@items;

	return $args;
}

sub _getImage {
	my ($imageList, $hires) = @_;
	my @candidates = map {
 		$_->{url};
 	} sort {
 		# sort by size descending
 		$b->{width} <=> $a->{width};
 	} values %$imageList;

	# return either the highest or lowest resolution
	return ($hires || $prefs->get('highres_icons')) ? $candidates[0] : $candidates[-1];
}

sub trackInfoMenu {
	my ($client, $url, $track, $remoteMeta) = @_;

	my $artist = ($remoteMeta && $remoteMeta->{artist}) || ($track && $track->artistName) || '';
	my $album  = ($remoteMeta && $remoteMeta->{album}) || ($track && $track->album && $track->album->name) || '';
	my $title  = ($remoteMeta && $remoteMeta->{title}) || ($track && $track->title) || '';

	if ($artist || $title || $album) {
		return {
			type      => 'outline',
			name      => cstring($client, 'PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => \&searchHandler,
			passthrough => [ { q => "($artist)+($title)" } ],
		};
	}

	return;
}

sub albumInfoMenu {
	my ($client, $url, $album, $remoteMeta) = @_;

	my $albumTitle = ($remoteMeta && $remoteMeta->{album}) || ($album && $album->title);

	my @artists;
	push @artists, $album->artistsForRoles('ARTIST'), $album->artistsForRoles('ALBUMARTIST');
	my $artist = $artists[0]->name;

	if ($albumTitle) {
		return {
			type      => 'outline',
			name      => cstring($client, 'PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => \&searchHandler,
			passthrough => [ { type => 'video,channel,playlist', q => "($artist)+($albumTitle)" } ],
		};
	}

	return;
}

sub artistInfoMenu {
	my ($client, $url, $obj, $remoteMeta) = @_;

	my $artist = ($remoteMeta && $remoteMeta->{artist}) || ($obj && $obj->name);

	if ($artist) {
		return {
			type      => 'outline',
			name      => cstring($client, 'PLUGIN_YOUTUBE_ON_YOUTUBE'),
			url       => \&searchHandler,
			passthrough => [ { type => 'video,channel,playlist', q => "($artist)" } ],
		};
	}

	return;
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

	return;
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
