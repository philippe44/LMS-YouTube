package Plugins::YouTube::HTTP;

use strict;

use base 'Slim::Networking::Async::HTTP';

use Slim::Utils::Log;

my $log = logger('plugin.youtube');

sub send_request {
	my ($self, $args, $redirect) = @_;
	$self->SUPER::send_request($args, 0) unless $redirect;
}

sub disconnect {
	my $self = shift;
	
	if ($self->socket && (!$self->response || !$self->response->previous || $self->response->header('connection') =~ /close/i)) {
		$log->info("closing persistent/special socket ", $self->socket);		
		$self->SUPER::disconnect;
	}	
}


1;
