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
	
	$log->error("ListPlayback with type: $type id: $id");
	Plugins::YouTube::API->searchVideos( sub {
		createPlaylist($client, Plugins::YouTube::Plugin::_renderList($_[0]->{items})); }, 
		{ $type => $id } );
		
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

=comment
sub contentType {
	return 'src';
}
=cut

sub isRemote { 1 }

=comment
sub cliPlayCombo {
	my $request = shift;
	
	$log->error("cliplaycombo");
	my $client = $request->client();
	my $albumId = $request->getParam('_p2');
	#my $action = $request->isCommand([['qobuz'], ['addalbum']]) ? 'addtracks' : 'playtracks';
	$client->execute( ["playlist", "play", "listref", $tracks] );
}
=cut	

1;
