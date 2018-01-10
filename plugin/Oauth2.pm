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

sub getToken {
	my $cb  = shift;
	my @params = @_;
	my $post = 	"client_id=" . $prefs->get('client_id') .
				"&client_secret=" . $prefs->get('client_secret');
					
	my 	$code = $cache->get('yt:device_code');		
	
	if (defined $code) {
		$post .= "&code=$code" .
				 "&grant_type=http://oauth.net/grant_type/device/1.0";
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
				
				$cache->remove('yt:user_code');
				$cache->remove('yt:verification_url');
				$cache->remove('yt:device_code');
			
				$log->debug("content:", $response->content);
								
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


sub getCode {
	my $post =	"client_id=" . $prefs->get('client_id') .
				"&scope=https://www.googleapis.com/auth/youtube.readonly";	
	
	$cache->remove('yt:user_code');
	$cache->remove('yt:verification_url');
	$cache->remove('yt:device_code');
	$cache->remove('yt:access_token');
						
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub { 
			my $response = shift;
			my $result = eval { from_json($response->content) };
						
			if ($@) {
				$log->error(Data::Dump::dump($response)) unless main::DEBUGLOG && $log->is_debug;
				$log->error($@);
			} else {
				$cache->set("yt:device_code", $result->{device_code}, $result->{expires_in});
				$cache->set("yt:verification_url", $result->{verification_url}, $result->{expires_in});
				$cache->set("yt:user_code", $result->{user_code}, $result->{expires_in});
									
				$log->debug("content:", $response->content);
			}
		},
		sub { 
			$log->error($_[1]);
		},
		{
			timeout => 15,
		}
	);
	
	$http->post(
		"https://accounts.google.com/o/oauth2/device/code",
		'Content-Type' => 'application/x-www-form-urlencoded',
		$post,
	);
}


1;
