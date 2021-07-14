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

		# get video first (search is video only) as adding 'playlist' does not return as many
		Plugins::YouTube::API->search( sub {
				my $result = shift;

				return renderItems($result, $cb) if $result->{total} >= $prefs->get('max_items');

				# then get playlists if remaining space
				Plugins::YouTube::API->searchDirect('playlists', sub {
						$result = { total => $result->{total} + $_[0]->{total},
									items => [ @{$result->{items}}, @{$_[0]->{items}} ] };
						renderItems($result, $cb);
					}, {
					 channelId => $id,
					_quantity 	=> $prefs->get('max_items') - $result->{total},
					}
				);
			}, { channelId => $id }
		);

	} elsif ($type eq 'playlistId') {

		Plugins::YouTube::API->searchDirect( 'playlistItems', sub {
				renderItems(shift, $cb);
			}, { playlistId => $id }
		);

	}
}

sub renderItems {
	my ($items, $cb) = @_;
	my $tracks = Plugins::YouTube::Plugin::_renderList($items);
	$tracks = [ map { $_->{play} } @{$tracks->{items}} ] if $main::VERSION lt '8.2.0';
	$cb->( $tracks );
}


1;
