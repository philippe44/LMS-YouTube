package Plugins::YouTube::Settings;
use base qw(Slim::Web::Settings);

use strict;

use List::Util qw(min max);
use Data::Dumper;

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log   = logger('plugin.youtube');

sub name {
	return 'PLUGIN_YOUTUBE';
}

sub page {
	return 'plugins/YouTube/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.youtube'), qw(country max_items APIkey prefer_lowbitrate));
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

	$params->{pref_max_items} = min($params->{pref_max_items}, 500);
	
	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

	
1;
