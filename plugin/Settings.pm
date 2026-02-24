package Plugins::YouTube::Settings;
use base qw(Slim::Web::Settings);

use strict;

use List::Util qw(min max);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

require Plugins::YouTube::Update_yt_dlp;

my $log   = logger('plugin.youtube');
my $cache = Slim::Utils::Cache->new();
my $prefs = preferences('plugin.youtube');

my @bool = qw(live_edge aac vorbis opus use_video highres_icons auto_update_ytdlp);

sub name {
	return 'PLUGIN_YOUTUBE';
}

sub page {
	return 'plugins/YouTube/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.youtube'), qw(channel_prefix channel_suffix playlist_prefix 
			playlist_suffix country max_items APIkey client_id client_secret live_delay 
			cache_ttl search_rank search_sort channel_rank channel_sort playlist_sort query_size auto_update_check_hour), @bool);
}

sub init {
	Plugins::YouTube::Update_yt_dlp->init();
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

=comment	
if ($params->{flushcache}) {
	$log->info('flushing cache');
	Plugins::YouTube::API::flushCache();
	Plugins::YouTube::ProtocolHandler::flushCache();
}
=cut

	my $current_binary = $params->{binary} || $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();

	# Clear version cache if binary selection changed
	if ($params->{saveSettings} && defined $params->{binary}) {
		my $old_binary = $prefs->get('yt_dlp') || '';
		if ($params->{binary} ne $old_binary) {
			$log->info("Binary changed, clearing version cache");
			Plugins::YouTube::Update_yt_dlp->clear_version_cache($old_binary);
			Plugins::YouTube::Update_yt_dlp->clear_version_cache($params->{binary});
		}
		$prefs->set('yt_dlp', $params->{binary});
	}

	# Handle yt-dlp update request
	Plugins::YouTube::Update_yt_dlp->handle_update_request($params, $current_binary);

	# Retrieve update status for UI
	Plugins::YouTube::Update_yt_dlp->get_update_status($params);

	Plugins::YouTube::Oauth2::getCode if $params->{get_code};
	
	$params->{user_code} = $cache->get('yt:user_code');
	$params->{verification_url} = $cache->get('yt:verification_url');
	$params->{access_code} = $cache->get('yt:access_code');
	$params->{authorize_link} = $cache->get('yt:verification_url');
	$params->{access_token} = $cache->get('yt:access_token');
	
	$params->{pref_max_items} = min($params->{pref_max_items}, 500);
	$params->{pref_live_delay} = max($params->{pref_live_delay}, 30);
	$params->{pref_APIkey} =~ s/^\s+|\s+$//g;
		
	$cache->remove('yt:access_token') if $params->{clear_token};
	
	foreach (@bool) {
		$params->{"pref_$_"} = 0 unless defined $params->{"pref_$_"};
	}
	
	$params->{binary} = $current_binary;
	$params->{binaries} = [ '', Plugins::YouTube::Utils::yt_dlp_binaries() ];

	$params->{last_auto_update} = Plugins::YouTube::Update_yt_dlp->get_last_auto_update();

	Plugins::YouTube::Update_yt_dlp->get_current_version($params, $current_binary);

	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

 
1;