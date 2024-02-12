package Plugins::YouTube::ListProtocolHandler;

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::YouTube::Plugin;

Slim::Player::ProtocolHandlers->registerHandler('ytplaylist', __PACKAGE__);

my $log = logger('plugin.youtube');
my $prefs = preferences('plugin.youtube');

sub canDirectStream { 0 }
sub contentType { 'youtube' }
sub isRemote { 1 }

sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;

	my ($type, $id) = $url =~ m|(?:ytplaylist)://([^\=]+)=(\S*)|i;
	return unless $type && $id;

	if ($type eq 'channelId') {
		Plugins::YouTube::Plugin::channelHandler($client, sub {
				my $tracks = shift;
				$tracks = [ map { $_->{play} } @{$tracks->{items}} ] if $main::VERSION lt '8.2.0';
				$cb->( $tracks );
			}, { }, { 
				channelId => $id,
				type => 'video',
			} 
		);
	} elsif ($type eq 'playlistId') {
		Plugins::YouTube::Plugin::playlistHandler($client, sub {
				my $tracks = shift;
				$tracks = [ map { $_->{play} } @{$tracks->{items}} ] if $main::VERSION lt '8.2.0';
				$cb->( $tracks );
			}, { }, { 
				playlistId => $id 
			}
		);

	}
}

1;
