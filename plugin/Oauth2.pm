package Plugins::YouTube::Oauth2;

use strict;

use Data::Dumper;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(string cstring);
use JSON::XS::VersionOneAndTwo;

my $log   = logger('plugin.youtube');
my $prefs = preferences('plugin.youtube');
my $cache = Slim::Utils::Cache->new();

sub oauth2callback {
	my ( $client, $params, undef, undef, $response ) = @_;
		
	$response->content_type( "text/plain" );
	my $body = $params->{url_query};
	my ($code) = ( $params->{url_query} =~ /code=(.*)/ );
	
	return cstring($client, 'PLUGIN_YOUTUBE_OAUTHFAILED') if !defined $code;
	
	getToken($code);
		
	return \cstring($client, 'PLUGIN_YOUTUBE_OAUTHSUCCESS');
}

sub getToken {
	my $code = shift;
	my $cb  = shift;
	my @params = @_;
	my $post = 	"client_id=" . $prefs->get('client_id') .
				"&client_secret=" . $prefs->get('client_secret') .
				"&redirect_uri=http://localhost:9000/plugins/youtube/oauth2callback";
					
	if (defined $code) {
		$post .= "&code=$code" .
				 "&grant_type=authorization_code";
	} else {
		$post .= "&refresh_token=" . $prefs->get('refresh_token') .
				 "&grant_type=refresh_token";
	}
				
    my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub { 
			my $response = shift;
			my $result = eval { from_json($response->content) };
			
			if ($@) {
				$log->error(Data::Dump::dump($response)) unless main::DEBUGLOG && $log->is_debug;
				$log->error($@);
			} else {
				$cache->set("yt:access_token", $result->{access_token}, $result->{expires_in} - 60);
				$prefs->set('refresh_token', $result->{refresh_token}) if $result->{refresh_token};
			
				$log->debug("content:", $response->content);
				$log->info("access_token:", $result->{access_token});
				$log->info("refresh_token:", $result->{refresh_token}) if $result->{refresh_token};
				
				$cb->(@params) if $cb;
			}
		},
		sub { 
			$log->error($_[1]);
			$cb->(@params) if $cb;
		},
		{
			timeout => 15,
		}
	);
	
	$http->post(
		"https://accounts.google.com/o/oauth2/token",
		'Content-Type' => 'application/x-www-form-urlencoded',
		$post,
	);
}


sub authorize {
	my $url =	"https://accounts.google.com/o/oauth2/auth?" .
				"client_id=" . $prefs->get('client_id') .
				"&redirect_uri=http://localhost:9000/plugins/youtube/oauth2callback" .
				"&scope=https://www.googleapis.com/auth/youtube.readonly&response_type=code&access_type=offline";	
				
	return $url;				
}


1;
