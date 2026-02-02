package Plugins::YouTube::Settings;
use base qw(Slim::Web::Settings);

use strict;

use List::Util qw(min max);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings;

my $log   = logger('plugin.youtube');
my $cache = Slim::Utils::Cache->new();
my $prefs = preferences('plugin.youtube');

my @bool = qw(live_edge aac vorbis opus use_video highres_icons);

sub name {
	return 'PLUGIN_YOUTUBE';
}

sub page {
	return 'plugins/YouTube/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.youtube'), qw(channel_prefix channel_suffix playlist_prefix 
			playlist_suffix country max_items APIkey client_id client_secret live_delay 
			cache_ttl search_rank search_sort channel_rank channel_sort playlist_sort query_size), @bool);
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

	if ($params->{saveSettings}) {
		$prefs->set( 'yt_dlp', $params->{binary} );
	}

	# Handle yt-dlp update
	if ($params->{update_ytdlp}) {
		_updateYtDlp($params);
	}

	Plugins::YouTube::Oauth2::getCode if $params->{get_code};
	
	$params->{user_code} = $cache->get('yt:user_code');
	$params->{verification_url} = $cache->get('yt:verification_url');
	$params->{access_code} = $cache->get('yt:access_code');
	$params->{authorize_link} = $cache->get('yt:verification_url');
	$params->{access_token} = $cache->get('yt:access_token');
	
	$params->{pref_max_items} = min($params->{pref_max_items}, 500);
	$params->{pref_live_delay} = max($params->{pref_live_delay}, 30);
	$params->{pref_APIkey} =~ s/^\s+|\s+$//g;
		
	$cache->remove('yt:access_token') if $params->{clear_token};
	
	foreach (@bool) {
		$params->{"pref_$_"} = 0 unless defined $params->{"pref_$_"};
	}
	
	$params->{binary} = $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();
	$params->{binaries} = [ '', Plugins::YouTube::Utils::yt_dlp_binaries() ];

	# Get current version on every page load
	_getCurrentVersion($params);
				
	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

sub _updateYtDlp {
	my $params = shift;

	my $binary = $params->{binary} || $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();
	my $bin_path = Plugins::YouTube::Utils::yt_dlp_bin($binary);

	unless ($bin_path && -e $bin_path) {
		$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_BINARY_NOT_FOUND');
		$params->{update_error} = 1;
		$log->error("yt-dlp binary not found: $binary");
		return;
	}

	$log->info("Updating yt-dlp binary: $bin_path");

	# Check if we're on Windows
	if ($^O =~ /^MSWin/) {
		_updateYtDlpWindows($bin_path, $params);
	} else {
		_updateYtDlpUnix($bin_path, $params);
	}
}

sub _getCurrentVersion {
	my $params = shift;

	my $binary = $params->{binary} || $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();
	my $bin_path = Plugins::YouTube::Utils::yt_dlp_bin($binary);

	# Check cache first (cache for 1 hour to avoid repeated calls)
	my $cache_key = 'yt:version:' . $binary;
	my $cached_version = $cache->get($cache_key);

	if ($cached_version) {
		$params->{current_version} = $cached_version;
		return;
	}

	unless ($bin_path && -e $bin_path) {
		$params->{current_version} = 'N/A';
		return;
	}

	eval {
		my $version_output = '';

		# Unified version check for both OS types
		# Redirect stderr to stdout to handle warnings gracefully
		$version_output = `"$bin_path" --version 2>&1`;

		chomp($version_output);

		# Extract version (yt-dlp outputs just the version number, e.g., 2023.03.04)
		if ($version_output && $version_output =~ /(\d{4}\.\d{2}\.\d{2})/) {
			$params->{current_version} = $1;
			$cache->set($cache_key, $1, 3600); # Cache for 1 hour
			$log->info("Current yt-dlp version: $1");
		} else {
			$params->{current_version} = 'Unknown';
			$log->warn("Could not parse yt-dlp version from: $version_output");
		}
	};

	if ($@) {
		$params->{current_version} = 'Error';
		$log->error("Error getting yt-dlp version: $@");
	}
}

sub _updateYtDlpUnix {
	my ($bin_path, $params) = @_;

	eval {
		my $output_buffer = '';

		# Set write permission (0755)
		unless (Plugins::YouTube::Utils::set_yt_dlp_writable($bin_path)) {
			die "Failed to set write permission on $bin_path";
		}

		require AnyEvent::Util;

		my $cmd = [$bin_path, '-U'];

		# Capture output using subroutines
		my $cv = AnyEvent::Util::run_cmd($cmd,
			'>'  => sub { $output_buffer .= $_[0] if defined $_[0]; },
			'2>' => sub { $output_buffer .= $_[0] if defined $_[0]; }
		);

		my $exit_code = $cv->recv;

		# Restore safe permissions (0555)
		Plugins::YouTube::Utils::set_yt_dlp_readonly($bin_path);

		# Clean up output: replace newlines with spaces and trim ends
		$output_buffer =~ s/\r?\n/ /g;
		$output_buffer =~ s/^\s+|\s+$//g;

		if ($exit_code == 0) {
			if ($output_buffer =~ /up to date/i) {
				$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_VERSION_UP_TO_DATE');
				$log->info("yt-dlp update status: $output_buffer");
			} else {
				$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_SUCCESS');
				$log->info("yt-dlp update output: $output_buffer");
			}
			$params->{update_error} = 0;

			# Clear version cache
			my $binary = $params->{binary} || $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();
			my $cache_key = 'yt:version:' . $binary;
			$cache->remove($cache_key);
		} else {
			$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_FAILED') . " (exit code: $exit_code)";
			$params->{update_error} = 1;
			$log->error("yt-dlp update failed (code $exit_code): $output_buffer");
		}
	};

	if ($@) {
		my $error_msg = $@;
		# Restore permissions safely
		eval { Plugins::YouTube::Utils::set_yt_dlp_readonly($bin_path); };

		$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_ERROR') . ": $error_msg";
		$params->{update_error} = 1;
		$log->error("Error updating yt-dlp: $error_msg");
	}
}

sub _updateYtDlpWindows {
	my ($bin_path, $params) = @_;

	eval {
		# Use backticks to capture output (STDOUT merged with STDERR)
		my $cmd = "\"$bin_path\" -U 2>&1";

		$log->info("Executing update command: $cmd");
		my $output_buffer = `$cmd`;
		my $exit_code = $? >> 8;

		# Clean up output
		$output_buffer =~ s/\r?\n/ /g;
		$output_buffer =~ s/^\s+|\s+$//g;

		if ($exit_code == 0) {
			if ($output_buffer =~ /up to date/i) {
				$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_VERSION_UP_TO_DATE');
				$log->info("yt-dlp update status: $output_buffer");
			} else {
				$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_SUCCESS');
				$log->info("yt-dlp update output: $output_buffer");
			}
			$params->{update_error} = 0;

			# Clear version cache to force refresh
			my $binary = $params->{binary} || $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();
			my $cache_key = 'yt:version:' . $binary;
			$cache->remove($cache_key);
		} else {
			# Even if exit code is non-zero, the output might contain useful info
			$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_FAILED') . " (exit code: $exit_code)";
			$params->{update_error} = 1;
			$log->error("yt-dlp update failed with exit code $exit_code: $output_buffer");
		}
	};

	if ($@) {
		$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_ERROR') . ": $@";
		$params->{update_error} = 1;
		$log->error("Error updating yt-dlp (Windows): $@");
	}
}
	
1;
