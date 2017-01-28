package Plugins::YouTube::Settings;
use base qw(Slim::Web::Settings);

use strict;

use List::Util qw(min max);
use Data::Dumper;

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log   = logger('plugin.youtube');
my $cache = Slim::Utils::Cache->new();

sub name {
	return 'PLUGIN_YOUTUBE';
}

sub page {
	return 'plugins/YouTube/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.youtube'), qw(channel_prefix channel_suffix playlist_prefix playlist_suffix country max_items APIkey client_id client_secret));
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

	$params->{authorize} = Plugins::YouTube::Oauth2::authorize();
	$params->{pref_max_items} = min($params->{pref_max_items}, 500);
	$cache->remove('yt:access_token') if $params->{clear_token};
	
	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

	
1;
