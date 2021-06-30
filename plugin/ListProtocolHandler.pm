package Plugins::YouTube::ListProtocolHandler;

use strict;

use Slim::Utils::Log;

use Plugins::YouTube::Plugin;

Slim::Player::ProtocolHandlers->registerHandler('ytplaylist', __PACKAGE__);

my $log = logger('plugin.youtube');

sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;
	
	my ($type, $id) = $url =~ m|(?:ytplaylist)://([^\=]+)=(\S*)|i;
	return unless $type && $id;

	if ($type eq 'channelId') {
	
		Plugins::YouTube::API->search( sub {
				my $tracks = Plugins::YouTube::Plugin::_renderList($_[0]);
				$tracks = [ map { $_->{play} } @{$tracks->{items}} ] if $main::VERSION < 8.2.0;
				$cb->( $tracks ); 
			}, 
			{ channelId => $id, type => 'video' }, 
		);
			
	} elsif ($type eq 'playlistId') {
		
		Plugins::YouTube::API->searchDirect( 'playlistItems', sub {
				my $tracks = Plugins::YouTube::Plugin::_renderList($_[0]);
				$tracks = [ map { $_->{play} } @{$tracks->{items}} ] if $main::VERSION < 8.2.0;				
				$cb->( $tracks ); 
			}, 
			{ playlistId => $id },
		);
		
	}
}

sub canDirectStream { 0 }
sub contentType { 'youtube' }
sub isRemote { 1 }


1;
