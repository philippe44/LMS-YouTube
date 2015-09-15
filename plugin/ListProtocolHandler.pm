package Plugins::YouTube::ListProtocolHandler;

use strict;

use Data::Dumper;

use Slim::Utils::Log;

use Plugins::YouTube::API;
use Plugins::YouTube::ProtocolHandler;
use Plugins::YouTube::Plugin;

Slim::Player::ProtocolHandlers->registerHandler('ytplaylist', __PACKAGE__);

my $log = logger('plugin.youtube');

sub overridePlayback {
	my ( $class, $client, $url ) = @_;
		
	if ( $url !~ m|(?:ytplaylist)://([^\=]+)=(\S*)|i ) {
		return undef;
	}
	
	my ($type, $id) = ($1, $2);
	
	if ($type eq 'channelId') {
	
		Plugins::YouTube::API->search( sub {
			createPlaylist($client, Plugins::YouTube::Plugin::_renderList($_[0]->{items})); }, 
			{ channelId => $id, type => 'video' } );
			
	} elsif ($type eq 'playlistId') {
	
		Plugins::YouTube::API->getPlaylist( sub {
			createPlaylist($client, Plugins::YouTube::Plugin::_renderList($_[0]->{items})); }, 
			{ playlistId => $id } );
			
	}
			
	return 1;
}

sub createPlaylist {
	my ( $client, $items ) = @_;
	my @urls;
		
	for my $item (@{$items}) {
		push @urls, $item->{play} if $item->{play};
	}	
	
	$client->execute([ 'playlist', 'clear' ]);
	$client->execute([ 'playlist', 'addtracks', 'listRef', \@urls ]);
	$client->execute([ 'play' ]);
}

sub canDirectStream {
	return 1;
}

sub contentType {
	return 'youtube';
}

sub isRemote { 1 }


1;
