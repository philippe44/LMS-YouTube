package Plugins::YouTube::Settings;
use base qw(Slim::Web::Settings);

use strict;

use List::Util qw(min max);
use File::Spec;
use Time::HiRes;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings;
use Slim::Utils::Timers;

my $log   = logger('plugin.youtube');
my $cache = Slim::Utils::Cache->new();
my $prefs = preferences('plugin.youtube');

my %ALLOWED_BINARIES = map { $_ => 1 } ('', Plugins::YouTube::Utils::yt_dlp_binaries());

my @bool = qw(live_edge aac vorbis opus use_video highres_icons);

use constant VERSION_CACHE_TTL => 3600;  # 1 hour cache for version info
use constant UPDATE_CHECK_INTERVAL => 2; # Check every 3 seconds
use constant UPDATE_MAX_CHECKS => 15;    # Maximum 15 checks (30 seconds total)

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

	# Clear version cache if binary selection changed
	if ($params->{saveSettings} && defined $params->{binary}) {
		if (exists $ALLOWED_BINARIES{$params->{binary}}) {
			my $old_binary = $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();
			if ($params->{binary} ne $old_binary) {
				$log->info("Binary changed from $old_binary to $params->{binary}, clearing version cache");
				$cache->remove('yt:version:' . $old_binary);
				$cache->remove('yt:version:' . $params->{binary});
			}
			$prefs->set('yt_dlp', $params->{binary});
		} else {
			$log->error("Attempted to save non-whitelisted binary: $params->{binary}");
		}
	}

	# Handle yt-dlp update
	if ($params->{update_ytdlp}) {
	# Validate before even calling _updateYtDlp
	my $binary_to_update = $params->{binary} || $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();

	unless ($ALLOWED_BINARIES{$binary_to_update}) {
			$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_INVALID_BINARY') || 'Invalid binary';
			$params->{update_error} = 1;
			$log->error("Attempted to update non-whitelisted binary: $binary_to_update");
	} else {
			# Update preference if needed
			if ($params->{binary} && $params->{binary} ne ($prefs->get('yt_dlp') || '')) {
					$log->info("Saving new binary preference before update: $params->{binary}");
					$prefs->set('yt_dlp', $params->{binary});
					$cache->remove('yt:version:' . $params->{binary});
			}
			_updateYtDlp($params);
	}
}

	# Check for update status from cache
	my $cached_status = $cache->get('yt:update_status');
	if ($cached_status) {
		if ($cached_status eq 'in_progress') {
			$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATING') || 'Update in progress...';
			$params->{update_in_progress} = 1;
			$params->{update_error} = 0;
		} else {
			$params->{update_status} = $cached_status;
			$params->{update_error} = $cache->get('yt:update_error') || 0;
			$params->{update_in_progress} = 0;
			# Clear the status after displaying it (unless still in progress)
			$cache->remove('yt:update_status');
			$cache->remove('yt:update_error');
		}
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
	$params->{binaries} = [ sort keys %ALLOWED_BINARIES ];

	# Get current version AFTER potential update
	_getCurrentVersion($params);
				
	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

sub _updateYtDlp {
	my $params = shift;
	my $binary = $params->{binary} || $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();

	# Validate binary is in the allowed list to prevent arbitrary code execution
	unless ($ALLOWED_BINARIES{$binary}) {
		$params->{update_status} = (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_INVALID_BINARY') || 'Invalid binary selection') . ": $binary";
		$params->{update_error} = 1;
		$log->error("Attempted to update non-whitelisted binary: $binary");
		return;
	}

	my $bin_path = Plugins::YouTube::Utils::yt_dlp_bin($binary);

	unless ($bin_path && -e $bin_path) {
		$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_BINARY_NOT_FOUND') || 'Binary not found';
		$params->{update_error} = 1;
		$log->error("yt-dlp binary not found: $binary");
		return;
	}

	$log->info("Updating yt-dlp binary: $bin_path");

	# Set initial status
	$cache->set('yt:update_status', 'in_progress', 300);
	$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_IN_PROGRESS') || 'Update in progress...';
	$params->{update_error} = 0;
	$params->{update_in_progress} = 1;

	# Start the update process in background
	_startYtDlpUpdate($bin_path, $binary);
}

sub _startYtDlpUpdate {
	my ($bin_path, $binary) = @_;
	my $permissions_changed = 0;
	my $temp_output = File::Spec->catfile(
		Slim::Utils::Prefs::preferences('server')->get('cachedir'),
		'yt_dlp_update.txt'
	);

	eval {
		require Proc::Background;

		# Unix: temporarily set write permission
		if (!main::ISWINDOWS) {
			Plugins::YouTube::Utils::set_yt_dlp_writable($bin_path)
				or die "Failed to set write permissions on $bin_path";
			$permissions_changed = 1;
			$log->info("Write permissions temporarily enabled for $bin_path");
		}

		# Ensure output file is writable and empty
		if (open(my $fh, '>', $temp_output)) {
			close($fh);
			$log->debug("Created output file: $temp_output");
		} else {
			die "Cannot create output file $temp_output: $!";
		}

		# Start background process with output redirected using shell redirection
		my $proc;

		if (main::ISWINDOWS) {
			# Windows: Quote paths properly for cmd.exe
			my $quoted_bin = $bin_path;
			$quoted_bin =~ s/"/\\"/g;  # Escape any quotes
			my $quoted_out = $temp_output;
			$quoted_out =~ s/"/\\"/g;
			my $cmd = "\"$quoted_bin\" -U > \"$quoted_out\" 2>&1";
			$log->debug("Windows command: $cmd");
			$proc = Proc::Background->new($cmd);
		} else {
			# Unix: Use single quotes to avoid shell expansion issues
			my $escaped_bin = $bin_path;
			$escaped_bin =~ s/'/'\\''/g;  # Escape single quotes for shell
			my $escaped_out = $temp_output;
			$escaped_out =~ s/'/'\\''/g;
			my $cmd = "'$escaped_bin' -U > '$escaped_out' 2>&1";
			$log->debug("Unix command: $cmd");
			$proc = Proc::Background->new($cmd);
		}

		unless ($proc) {
			die "Failed to start background process";
		}

		my $pid = $proc->pid;
		$log->info("yt-dlp update started (PID: $pid), output to: $temp_output");

		# Set up timer to check for completion
		Slim::Utils::Timers::setTimer(
			undef,  # No specific client
			Time::HiRes::time() + UPDATE_CHECK_INTERVAL,
			sub {
				_checkUpdateProgress($proc, $temp_output, $bin_path, $binary, $permissions_changed, 1);
			}
		);
	};

	if ($@) {
		my $error = $@;
		$log->error("Error starting yt-dlp update: $error");
		$cache->set('yt:update_status',
			(Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_ERROR') || 'Update error') . ": $error",
			300);
		$cache->set('yt:update_error', 1, 300);

		# Restore permissions if they were changed
		if ($permissions_changed && !main::ISWINDOWS) {
			eval {
				Plugins::YouTube::Utils::set_yt_dlp_readonly($bin_path);
				$log->info("Permissions restored after startup error");
			};
			if ($@) {
				$log->error("CRITICAL: Failed to restore safe permissions on $bin_path: $@");
				my $current_status = $cache->get('yt:update_status') || '';
				my $perm_warn = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_RESTORE_PERMISSION_WARNING') || ' WARNING: Could not restore file permissions!';
					$cache->set('yt:update_status', $current_status . " " . $perm_warn, 300);
			}
		}

		# Clean up temp file if it exists
		unlink($temp_output) if -e $temp_output;
	}
}

sub _checkUpdateProgress {
	my ($proc, $temp_output, $bin_path, $binary, $permissions_changed, $attempt) = @_;

	if ($proc->alive) {
		# Still running - check again if we haven't exceeded max attempts
		if ($attempt < UPDATE_MAX_CHECKS) {
			Slim::Utils::Timers::setTimer(
				undef,
				Time::HiRes::time() + UPDATE_CHECK_INTERVAL,
				sub {
					_checkUpdateProgress($proc, $temp_output, $bin_path, $binary, $permissions_changed, $attempt + 1);
				}
			);
			$log->debug("yt-dlp update still running (check $attempt/" . UPDATE_MAX_CHECKS . ")");
		} else {
			# Timeout after maximum checks
			my $timeout_secs = UPDATE_CHECK_INTERVAL * UPDATE_MAX_CHECKS;
			$log->warn("yt-dlp update still running after ${timeout_secs}s, stopping status checks (process continues)");

			my $timeout_msg = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_TIMEOUT')
				|| "Update is taking longer than expected (>${timeout_secs}s). The process is still running in the background.";

			$cache->set('yt:update_status', $timeout_msg, 300);
			$cache->set('yt:update_error', 0, 300);  # Not an error, just slow

			# Don't restore permissions yet - update might still be running
			$log->warn("Permissions will remain writable until update completes or server restarts");
		}
		return;
	}

	# Process finished - get exit code and output
	$log->info("yt-dlp update process completed");

	my $exit_code = $proc->wait;
	my $output = '';

	# Read output from temp file
	if (-e $temp_output) {
		if (open(my $fh, '<', $temp_output)) {
			local $/;
			$output = <$fh>;
			close($fh);
			$log->debug("Read " . length($output) . " bytes from update output");
			unlink($temp_output);
		} else {
			$log->warn("Could not read update output file: $!");
		}
	} else {
		$log->warn("Update output file not found: $temp_output");
	}

	# Process results
	_handleYtDlpUpdateResult($output, $exit_code, $binary);

	# ALWAYS restore permissions on Unix, even if update failed
	if ($permissions_changed && !main::ISWINDOWS) {
		eval {
			Plugins::YouTube::Utils::set_yt_dlp_readonly($bin_path);
			$log->info("Permissions successfully restored for $bin_path");
		};
		if ($@) {
			$log->error("CRITICAL: Failed to restore safe permissions on $bin_path: $@");
			$log->error("SECURITY RISK: Binary may remain writable!");
			# Also update the user-visible status
			my $current_status = $cache->get('yt:update_status') || '';
			$cache->set('yt:update_status',
				$current_status . " WARNING: Could not restore file permissions!",
				300);
		}
	}
}

sub _handleYtDlpUpdateResult {
	my ($output, $exit_code, $binary) = @_;

	$output =~ s/\r?\n/ /g;
	$output =~ s/^\s+|\s+$//g;

	my $status;
	my $error = 0;

	# Check for errors in the output regardless of exit code
			# Success handling - check for warnings separately
			if ($output =~ /warning/i) {
					$log->warn("Update succeeded with warnings: $output");
			}

	if ($exit_code != 0 || $output =~ /(?:permission\s+denied|fatal\s+error|cannot\s+update)/i) {
		$output =~ s/\s+$//;
		$status = (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_FAILED') || 'Update failed')
			. ": $output";
		$error = 1;
	}
	elsif ($exit_code == 0) {
		# Success - parse output to determine what happened
		if ($output =~ /warning/i) {
			$log->warn("Update succeeded with warnings: $output");
		}
		if ($output =~ /up[- ]to[- ]date/i) {
			$status = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_VERSION_UP_TO_DATE')
				|| 'yt-dlp is already up to date';
		}
		elsif ($output =~ /updated.*(?:to|version)\s+(\S+)/i) {
			my $version = $1;
			$status = (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_SUCCESS') || 'Update successful')
				. " (" . (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_VERSION') || 'version')
				. ": $version)";
		}
		elsif (!$output || $output eq '') {
			# Empty output but successful exit - maybe already up to date or silent success
			$status = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_SUCCESS')
				|| 'yt-dlp updated successfully (no output)';
			$log->warn("yt-dlp update succeeded but produced no output");
		}
		else {
			$status = (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_FAILED') || 'Update failed')
				. ": " . (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UNEXPECTED_RESPONSE') || 'Unexpected response from binary');
			$error = 1;
			$log->warn("yt-dlp update returned 0 but output was suspicious: $output");
		}
	}
	else {
		$status = (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_FAILED') || 'Update failed')
			. " (" . (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_EXIT') || 'Exit code')
			. ": $exit_code)";
		$error = 1;
		$log->error("yt-dlp update failed (exit code $exit_code): $output");
	}

	if (!$error) {
		$cache->remove('yt:version:' . $binary);
		$log->info("yt-dlp update successful: $output");
	} else {
		$log->error("yt-dlp update error: $output");
	}

	# Store result in cache for the web UI to retrieve
	$cache->set('yt:update_status', $status, 300);
	$cache->set('yt:update_error', $error, 300);
}

sub _getCurrentVersion {
	my $params = shift;

	my $binary = $params->{binary} || $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();

	# Validate binary
	unless (exists $ALLOWED_BINARIES{$binary}) {
		$params->{current_version} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_INVALID_BINARY') || 'Invalid Binary';
		$log->error("Attempted to get version for non-whitelisted binary: $binary");
		return;
	}

	my $bin_path = Plugins::YouTube::Utils::yt_dlp_bin($binary);

	# Check cache first (cache for 1 hour to avoid repeated calls)
	my $cache_key = 'yt:version:' . $binary;
	my $cached_version = $cache->get($cache_key);

	if ($cached_version) {
		$params->{current_version} = $cached_version;
		return;
	}

	unless ($bin_path && -e $bin_path) {
	$params->{current_version} = Slim::Utils::Strings::string('NOT_AVAILABLE') || 'N/A';
		return;
	}

	eval {
		my $version_output = '';

		# Get version - redirect stderr to stdout to handle warnings gracefully
		# Use qx// (backticks) with proper quoting
		if (main::ISWINDOWS) {
			$version_output = `"$bin_path" --version 2>&1`;
		} else {
			# On Unix, properly escape the path
			my $escaped_path = $bin_path;
			$escaped_path =~ s/'/'\\''/g;
			$version_output = `'$escaped_path' --version 2>&1`;
		}

		chomp($version_output);

		# Extract version (yt-dlp outputs just the version number, e.g., 2023.03.04)
		if ($version_output && $version_output =~ /(\d{4}\.\d{2}\.\d{2}(?:\.\d+)?(?:-\w+)?)/) {
			my $version = $1;
			$params->{current_version} = $version;
			$cache->set($cache_key, $version, VERSION_CACHE_TTL);
			$log->info("Current yt-dlp version ($binary): $version");
		} else {
			$params->{current_version} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_VERSION_UNKNOWN') || 'Unknown';
			$log->warn("Could not parse yt-dlp version from: $version_output");
		}
	};

	if ($@) {
		$params->{current_version} = 'Error';
		$log->error("Error getting yt-dlp version: $@");
	}
}


1;