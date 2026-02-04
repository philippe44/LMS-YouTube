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
use constant UPDATE_CHECK_INTERVAL => 2; # Check every 2 seconds
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

# --- Helpers ---

sub _isValidBinary {
	my ($binary, $params) = @_;
	if (exists $ALLOWED_BINARIES{$binary // ''}) {
		return 1;
	}
	my $msg = (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_INVALID_BINARY') || 'Invalid binary') . ": $binary";
	_setUpdateStatus($params, $msg, 1);
	$log->error("Validation failed for binary: $binary");
	return 0;
}

sub _setUpdateStatus {
	my ($params, $msg, $is_error, $is_progress) = @_;

	# Sync to cache for AJAX polling
	$cache->set('yt:update_status', $is_progress ? 'in_progress' : $msg, 300);
	$cache->set('yt:update_error', $params->{update_error}, 300);

	# Update $params only if it was passed (main handler/initial startup)
	if (defined $params && ref $params eq 'HASH') {
		$params->{update_status} = $msg;
		$params->{update_error}  = $is_error ? 1 : 0;
		$params->{update_in_progress} = $is_progress ? 1 : 0;
	}
}

sub _restorePermissions {
	my ($bin_path, $params) = @_;

	return if main::ISWINDOWS || !$bin_path;

	eval {
		Plugins::YouTube::Utils::set_yt_dlp_readonly($bin_path);
		$log->info("Permissions successfully restored for $bin_path");
	};
	if ($@) {
		$log->error("CRITICAL: Failed to restore safe permissions on $bin_path: $@");

		# Append warning to existing status
		my $current_status = $cache->get('yt:update_status') || '';
		my $perm_warn = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_RESTORE_PERMISSION_WARNING')
			|| ' WARNING: Could not restore file permissions!';

		$cache->set('yt:update_status', $current_status . " " . $perm_warn, 300);

		# Update $params only if available
		if (defined $params) {
			$params->{update_status} .= " " . $perm_warn;
		}
	}
}

# --- Handler ---

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
	my $current_binary = $params->{binary} || $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();

=comment	
	if ($params->{flushcache}) {
		$log->info('flushing cache');
		Plugins::YouTube::API::flushCache();
		Plugins::YouTube::ProtocolHandler::flushCache();
	}
=cut

	# Clear version cache if binary selection changed
	if ($params->{saveSettings} && defined $params->{binary} && _isValidBinary($params->{binary}, $params)) {
		my $old_binary = $prefs->get('yt_dlp') || '';
		if ($params->{binary} ne $old_binary) {
			$log->info("Binary changed, clearing version cache");
			$cache->remove('yt:version:' . $old_binary);
			$cache->remove('yt:version:' . $params->{binary});
		}
		$prefs->set('yt_dlp', $params->{binary});
	}

	# Handle yt-dlp update
	if ($params->{update_ytdlp} && !defined $params->{t}) {
		if (($cache->get('yt:update_status') || '') ne 'in_progress') {
			if (_isValidBinary($current_binary, $params)) {
				_updateYtDlp($params, $current_binary);
			}
		}
	}

	# Retrieve Status for UI
	my $cached_status = $cache->get('yt:update_status');
	if ($cached_status) {
		if ($cached_status eq 'in_progress') {
			$params->{update_status} = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATING') || 'Update in progress...';
			$params->{update_in_progress} = 1;
		} else {
			$params->{update_status} = $cached_status;
			$params->{update_error}  = $cache->get('yt:update_error') || 0;
			$cache->remove('yt:update_status'); # Clear after one-shot display
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
	
	# $params->{binary} = $prefs->get('yt_dlp') || Plugins::YouTube::Utils::yt_dlp_binary();
	$params->{binary} = $current_binary;
	$params->{binaries} = [ '', Plugins::YouTube::Utils::yt_dlp_binaries() ];

	_getCurrentVersion($params, $current_binary);

	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

sub _updateYtDlp {
	my ($params, $binary) = @_;
	my $bin_path = Plugins::YouTube::Utils::yt_dlp_bin($binary);

	unless ($bin_path && -e $bin_path) {
		_setUpdateStatus($params, Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_BINARY_NOT_FOUND') || 'Binary not found', 1);
		return;
	}

	_setUpdateStatus($params, Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_IN_PROGRESS') || 'Starting...', 0, 1);
	_startYtDlpUpdate($bin_path, $binary, $params);
}

sub _startYtDlpUpdate {
	my ($bin_path, $binary, $params) = @_;
	my $permissions_changed = 0;
	my $temp_output = File::Spec->catfile(
		Slim::Utils::Prefs::preferences('server')->get('cachedir'),
		'yt_dlp_update.txt'
	);

	eval {
		my $proc;

		# Ensure output file is writable and empty
		if (open(my $fh, '>', $temp_output)) {
			close($fh);
			$log->debug("Created output file: $temp_output");
		} else {
			die "Cannot create output file $temp_output: $!";
		}

		if (main::ISWINDOWS) {
			require Win32::Process;

			# Windows: Use Win32::Process explicitly, nicked from ProtocolHandler.pm
			my $inner_cmd = qq{"$bin_path" -U > "$temp_output" 2>&1};
			my $cmd_line = qq{cmd.exe /c "$inner_cmd"};

			$log->info("Windows update command: $cmd_line");

			Win32::Process::Create(
				$proc,
				$ENV{COMSPEC} || 'C:\\Windows\\System32\\cmd.exe',
				$cmd_line,
				0,
				Win32::Process::NORMAL_PRIORITY_CLASS(),
				'.'
			) || die "Win32::Process::Create failed: " . Win32::FormatMessage(Win32::GetLastError());

			$log->info("yt-dlp update started (PID: " . $proc->GetProcessID() . "), output to: $temp_output");

		} else {
			# Unix
			require Proc::Background;

			Plugins::YouTube::Utils::set_yt_dlp_writable($bin_path)
				or die "Failed to set write permissions on $bin_path";
			$permissions_changed = 1;
			$log->info("Write permissions temporarily enabled for $bin_path");

			# Unix: Use single quotes to avoid shell expansion issues
			my $escaped_bin = $bin_path;
			$escaped_bin =~ s/'/'\\''/g;  # Escape single quotes for shell
			my $escaped_out = $temp_output;
			$escaped_out =~ s/'/'\\''/g;
			my $cmd = "'$escaped_bin' -U > '$escaped_out' 2>&1";
			$log->debug("Unix command: $cmd");

			$proc = Proc::Background->new($cmd) or die "Failed to start background process";
			$log->info("yt-dlp update started (PID: " . $proc->pid . "), output to: $temp_output");
		}
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
		_setUpdateStatus($params, (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_ERROR') || 'Update error') . ": $error", 1);

		_restorePermissions($bin_path, $params) if $permissions_changed;

		# Clean up temp file if it exists
		unlink($temp_output) if -e $temp_output;
	}
}

sub _checkUpdateProgress {
	my ($proc, $temp_output, $bin_path, $binary, $permissions_changed, $attempt) = @_;

	my $is_running = 0;
	my $exit_code;

	# Check process status based on platform
	if (main::ISWINDOWS) {
		$proc->GetExitCode($exit_code);
		if ($exit_code == Win32::Process::STILL_ACTIVE()) {
			$is_running = 1;
		}
	} else { #ISUNIX
		if ($proc->alive) {
			$is_running = 1;
		}
	}

	if ($is_running) {
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

			_setUpdateStatus(undef, $timeout_msg, 0, 0);

			$log->warn("Permissions will remain writable until update completes or server restarts");
		}
		return;
	}

	# Process finished
	$log->info("yt-dlp update process completed");

	if (!main::ISWINDOWS) {
		$exit_code = $proc->wait;
	}
	my $output = '';

	# Read output from temp file
	if (-e $temp_output) {
		my $size = -s $temp_output;
		if (open(my $fh, '<', $temp_output)) {
			local $/;
			$output = <$fh>;
			close($fh);
			$log->debug("Read " . length($output) . " bytes from update output (File size: $size)");
			unlink($temp_output);
		} else {
			$log->warn("Could not read update output file: $!");
		}
	} else {
		$log->warn("Update output file not found: $temp_output");
	}

	# Fallback if output is empty but exit code indicates failure
	if ((!$output || $output =~ /^\s*$/) && defined $exit_code && $exit_code != 0) {
		$output = "Command failed with exit code $exit_code (No output captured). Ensure Lyrion has write permissions to the 'Plugins/YouTube/Bin' folder.";
	}
	$cache->set('yt:update_in_progress', 0, 300);
	# Process results
	_handleYtDlpUpdateResult($output, $exit_code, $binary);

	# ALWAYS restore permissions, even if update failed
	_restorePermissions($bin_path, undef) if $permissions_changed;
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

	# exit code not conclusive
	if ($exit_code != 0 || $output =~ /(?:permission\s+denied|fatal\s+error|cannot\s+update|not\s+found|no\s+such\s+file)/i) {
		$output =~ s/\s+$//;
		$status = (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_FAILED') || 'Update failed') . ": " . ($output || "Unknown error");
		$error = 1;
		$log->error("yt-dlp update error: $output");
	}
	elsif ($output =~ /up[- ]to[- ]date/i) {
		$status = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_VERSION_UP_TO_DATE') || 'Already up to date';
		$log->info("yt-dlp up to date: $output");
	}
	elsif ($output =~ /updated/i || $output =~ /latest\s+version/i) {
		$status = Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UPDATE_SUCCESS') || 'Updated successfully';
		$cache->remove('yt:version:' . $binary);
		$log->info("yt-dlp update successful: $output");
	}
	else {
		$status = (Slim::Utils::Strings::string('PLUGIN_YOUTUBE_UNEXPECTED_RESPONSE') || 'Unexpected output') . ": " . ($output || "Unexpected output");
		$error = 1;
		$log->warn("yt-dlp update ambiguous result: $output");
	}

	# Store result in cache for the web UI to retrieve
	$cache->set('yt:update_status', $status, 300);
	$cache->set('yt:update_error', $error, 300);
}

sub _getCurrentVersion {
	my ($params, $binary) = @_;
	return unless _isValidBinary($binary);

	my $cache_key = 'yt:version:' . $binary;
	if (my $cached = $cache->get($cache_key)) {
		$params->{current_version} = $cached;
		return;
	}

	my $bin_path = Plugins::YouTube::Utils::yt_dlp_bin($binary);
	if ($bin_path && -e $bin_path) {
		my $cmd = main::ISWINDOWS ? qq{"$bin_path" --version 2>&1} : qq{'$bin_path' --version 2>&1};
		my $v = `$cmd`;
		if ($v =~ /(\d{4}\.\d{2}\.\d{2})/) {
			$params->{current_version} = $1;
			$cache->set($cache_key, $1, VERSION_CACHE_TTL);
			return;
		}
	}
	$params->{current_version} = Slim::Utils::Strings::string('NOT_AVAILABLE') || 'N/A';
}


1;