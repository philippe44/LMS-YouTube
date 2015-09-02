package Plugins::YouTube::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

sub name {
	return 'PLUGIN_YOUTUBE';
}

sub page {
	return 'plugins/YouTube/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.youtube'), qw(country max_items APIkey prefer_lowbitrate));
}

1;
