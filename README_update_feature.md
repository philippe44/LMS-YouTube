# YT-DLP Update Feature

## Overview

This feature adds self-update capability for the yt-dlp binary directly from the LMS YouTube plugin settings interface. Users can view their currently installed version and update yt-dlp with a single click, without requiring manual binary replacement or command-line access.

## Key Features

- **Version Display**: Current yt-dlp version shown automatically below binary selector
- **One-Click Updates**: Single "Update yt-dlp" button triggers background update process
- **Real-Time Status Updates**: AJAX polling provides live feedback without manual page refresh
- **Cross-Platform**: Works on Linux, macOS, Windows, and FreeBSD
- **Non-Blocking**: Update runs in background; server remains responsive
- **Automatic Version Refresh**: Version number updates dynamically after successful update
- **Visual Feedback**: Color-coded status messages, wait cursor, disabled button during update
- **Secure**: Temporary permission elevation on Unix systems, restored immediately after

## Architecture

### Backend (Perl)

**Settings.pm**:
- Non-blocking background updates using platform-specific process management
  - Windows: `Win32::Process` for process creation
  - Unix: `Proc::Background` for process management
- Timer-based status polling (checks every 2 seconds, max 30 seconds)
- Cache-based status management for persistence across page reloads
- Cross-platform implementation with platform-specific execution handling
- Enhanced error detection via keyword scanning and output analysis
- Binary whitelist validation for security

**Utils.pm**:
- `set_yt_dlp_writable()`: Temporarily sets write permissions (0755) on Unix
- `set_yt_dlp_readonly()`: Restores read-only permissions (0555) on Unix
- No permission changes on Windows (handled by OS)
- Automatic permission correction for non-executable binaries

### Frontend (HTML/JavaScript)

**basic.html**:
- CSS classes for status states (`.status-running`, `.status-success`, `.status-error`)
- AJAX polling via XMLHttpRequest to check update status every 2 seconds
- Dynamic DOM updates for status messages and version number
- Global wait cursor during updates (`document.documentElement.classList.add('wait')`)
- Button state management (disable/enable)

## User Workflow

1. **Navigate** to Settings → Advanced → YouTube
2. **View** current yt-dlp version displayed below binary selector dropdown
3. **Click** "Update yt-dlp" button
   - Button shows "Updating..." and is disabled
   - Wait cursor appears globally
   - Status shows "Updating..." in blue
4. **Status updates automatically** every 2 seconds via AJAX
5. **Update completes** (typically 5-10 seconds):
   - Success: Green message with new version number
   - Already up-to-date: Green message
   - Failure: Red message with error details
6. **Version number updates** automatically without page reload
7. **Button re-enables** automatically

## Technical Implementation

### Update Process Flow

```
User clicks button
    ↓
handler() detects 'update_ytdlp' parameter
    ↓
_updateYtDlp() validates binary, sets cache status to 'in_progress'
    ↓
_startYtDlpUpdate() starts background process
    ↓
    ┌──────────────────────────────┐
    │ Background Process           │
    │ (yt-dlp -U)                  │
    │ Output → temp file           │
    └──────────────────────────────┘
    ↓
_checkUpdateProgress() polls every 2s (up to 15 times)
    ↓
When complete:
    - Read output from temp file
    - Parse success/failure
    - Restore permissions (Unix)
    - Update cache with final status
    ↓
    ┌──────────────────────────────┐
    │ JavaScript AJAX Polling      │
    │ (Every 2 seconds)            │
    └──────────────────────────────┘
    ↓
Detects status changed from 'in_progress':
    - Update status message
    - Update version number
    - Re-enable button
    - Stop polling
```

### Unix/Linux/macOS/FreeBSD Execution

```perl
# Set temporary write permission
Plugins::YouTube::Utils::set_yt_dlp_writable($bin_path);  # 0755

# Execute update in background with shell redirection
my $escaped_bin = $bin_path;
$escaped_bin =~ s/'/'\\''/g;  # Escape single quotes for shell
my $escaped_out = $temp_output;
$escaped_out =~ s/'/'\\''/g;
my $cmd = "'$escaped_bin' -U > '$escaped_out' 2>&1";
my $proc = Proc::Background->new($cmd);

# Poll for completion
Slim::Utils::Timers::setTimer(..., sub { _checkUpdateProgress(...) });

# After completion, always restore permissions
Plugins::YouTube::Utils::set_yt_dlp_readonly($bin_path);  # 0555
```

### Windows Execution

```perl
# No permission changes needed
my $inner_cmd = qq{"$bin_path" -U > "$temp_output" 2>&1};
my $cmd_line = qq{cmd.exe /c "$inner_cmd"};

Win32::Process::Create(
    $proc,
    $ENV{COMSPEC} || 'C:\\Windows\\System32\\cmd.exe',
    $cmd_line,
    0,
    Win32::Process::NORMAL_PRIORITY_CLASS(),
    '.'
);

# Same polling mechanism as Unix
```

### Status Management

**Cache Keys**:
- `yt:update_status` - Current status message (TTL: 300s)
- `yt:update_error` - Boolean error flag (TTL: 300s)
- `yt:update_in_progress` - Update progress flag (TTL: 300s)
- `yt:version:{binary}` - Cached version info (TTL: 3600s)

**Status Values**:
- `'in_progress'` - Update is running (triggers AJAX polling)
- Success message - Update completed successfully
- Error message - Update failed with details

**Flow**:
1. Button click → `'in_progress'` set in cache
2. Page reload → Detects `'in_progress'` → Shows blue status → AJAX polling starts
3. Background completes → Cache updated with final status
4. Next AJAX poll → Detects change → Updates UI → Stops polling

### AJAX Polling Implementation

```javascript
[% IF update_in_progress %]
var pollInterval = setInterval(function() {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', window.location.href + '&t=' + Date.now(), true);
    xhr.onload = function() {
        var doc = new DOMParser().parseFromString(this.responseText, "text/html");
        var newStatus = doc.getElementById('update_status_message');
        var currentStatus = document.getElementById('update_status_message');

        if (newStatus && currentStatus) {
            currentStatus.innerHTML = newStatus.innerHTML;

            // Check if still running
            var isRunning = newStatus.innerHTML.indexOf('status-running') !== -1 ||
                            newStatus.innerHTML.indexOf('[% "PLUGIN_YOUTUBE_UPDATING" | string %]') !== -1;

            if (!isRunning) {
                clearInterval(pollInterval);
                document.documentElement.classList.remove('wait');

                // Update version number
                var newVersion = doc.getElementById('ytdlp_current_version');
                var currentVersion = document.getElementById('ytdlp_current_version');
                if (newVersion && currentVersion) {
                    currentVersion.innerHTML = newVersion.innerHTML;
                }

                // Re-enable button
                var btn = document.querySelector('input[name="update_ytdlp"]');
                if (btn) {
                    btn.disabled = false;
                    btn.style.cursor = '';
                    btn.value = "[% 'PLUGIN_YOUTUBE_UPDATE_YTDLP' | string %]";
                }
            }
        }
    };
    xhr.onerror = function() { isPolling = false; };
    xhr.send();
}, 2000);
[% END %]
```

## Error Handling

### Validation Errors
- **Invalid binary**: Selected binary not in whitelist → error before execution
- **Binary not found**: File doesn't exist → error before execution
- **Binary not executable**: Auto-corrected to 0555 permissions by `yt_dlp_bin()`

### Permission Errors (Unix)
- **Cannot set writable**: Update aborted, error logged and displayed
- **Cannot restore readonly**: Update succeeds but warning added to status message
- Critical security warning logged to server logs

### Execution Errors
- **Process fails to start**: Error caught and displayed with exception message
- **Non-zero exit code**: Failure message with exit code displayed
- **Timeout (>30s)**: Status checks stop, informational message shown, process continues

### Output Parsing
- **Empty output + exit 0**: Success with warning (silent update)
- **Contains "permission denied", "fatal error", "cannot update", "not found", or "no such file"**: Treated as error regardless of exit code
- **Exit 0 with suspicious output**: Flagged and logged, may show as success with warning
- **Cannot read output file**: Warning logged, relies on exit code only

### Recovery
- **Permissions remain writable**: Logged as critical security risk, needs manual intervention
- **Temp file not cleaned**: Logged but not critical, will be overwritten next time
- **Cache corruption**: Status automatically cleared after 5 minutes (TTL expires)

## Security

### Binary Whitelist
```perl
my %ALLOWED_BINARIES = map { $_ => 1 } ('', Plugins::YouTube::Utils::yt_dlp_binaries());
```
Only binaries from `yt_dlp_binaries()` can be updated. Prevents arbitrary binary execution.

### Path Escaping
```perl
# Unix: Escape single quotes for shell
my $escaped_bin = $bin_path;
$escaped_bin =~ s/'/'\\''/g;
my $cmd = "'$escaped_bin' -U > '$escaped_out' 2>&1";

# Windows: Quote paths and use cmd.exe
my $inner_cmd = qq{"$bin_path" -U > "$temp_output" 2>&1};
my $cmd_line = qq{cmd.exe /c "$inner_cmd"};

```

### Permission Management (Unix)
- **Default**: 0555 (r-xr-xr-x) - Read and execute only
- **During update**: 0755 (rwxr-xr-x) - Owner can write
- **After update**: 0555 restored immediately
- **On error**: Restoration attempted in all cases
- **Automatic correction**: Non-executable binaries are automatically set to 0555

### Cache Isolation
Update status stored in separate cache keys, not mixed with API or content cache.

## Configuration

### Constants (Settings.pm)
```perl
use constant VERSION_CACHE_TTL => 3600;       # 1 hour
use constant UPDATE_CHECK_INTERVAL => 2;      # 2 seconds
use constant UPDATE_MAX_CHECKS => 15;         # 30 seconds max
```

### Adjusting Behavior
- **Faster polling**: Change `UPDATE_CHECK_INTERVAL` to 1
- **Longer timeout**: Increase `UPDATE_MAX_CHECKS` to 30
- **Shorter version cache**: Reduce `VERSION_CACHE_TTL` to 1800

## Localization

Strings available in 4 languages (CS, DA, DE, EN):
- `PLUGIN_YOUTUBE_UPDATE_YTDLP` - "Update yt-dlp"
- `PLUGIN_YOUTUBE_UPDATING` - "Updating..."
- `PLUGIN_YOUTUBE_UPDATE_SUCCESS` - "yt-dlp update successful"
- `PLUGIN_YOUTUBE_VERSION_UP_TO_DATE` - "yt-dlp already up to date"
- `PLUGIN_YOUTUBE_UPDATE_FAILED` - "yt-dlp update failed"
- `PLUGIN_YOUTUBE_UPDATE_ERROR` - "yt-dlp update error"
- `PLUGIN_YOUTUBE_UPDATE_BINARY_NOT_FOUND` - "yt-dlp binary not found"
- `PLUGIN_YOUTUBE_CURRENT_VERSION` - "Current version"
- `PLUGIN_YOUTUBE_VERSION` - "version"
- `PLUGIN_YOUTUBE_EXIT` - "Exit code"
- `PLUGIN_YOUTUBE_INVALID_BINARY` - "Invalid binary selection"
- `PLUGIN_YOUTUBE_UNEXPECTED_RESPONSE` - "Unexpected response from binary"
- `PLUGIN_YOUTUBE_RESTORE_PERMISSION_WARNING` - "WARNING: Could not restore file permissions!"
- `PLUGIN_YOUTUBE_VERSION_UNKNOWN` - "Unknown"
- `PLUGIN_YOUTUBE_UPDATE_IN_PROGRESS` - "Update in progress..."
- `PLUGIN_YOUTUBE_UPDATE_TIMEOUT` - "Update is taking longer than expected..."
- `NOT_AVAILABLE` - "N/A"

## Dependencies

### Required Perl Modules
- **Windows**: `Win32::Process` - Windows process management
- **Unix**: `Proc::Background` - Unix background process management
- **File::Spec** - Path manipulation (core module)
- **Time::HiRes** - High-resolution timers (core module)
- **List::Util** - Utility functions (core module)
- **Slim::Utils::** - LMS framework modules (already present)

### Browser Requirements (for AJAX polling)
- XMLHttpRequest support (all modern browsers, IE10+)
- DOMParser support (all modern browsers)
- ClassList API (all modern browsers, IE10+)

**Graceful Degradation**: Without JavaScript, updates still work but require manual page refresh to see results.

## Files Modified

### Modified Files
- `plugins/YouTube/HTML/EN/plugins/YouTube/settings/basic.html` - UI with AJAX polling
- `plugins/YouTube/Settings.pm` - Backend update logic
- `plugins/YouTube/Utils.pm` - Permission management functions and binary detection
- `strings.txt` - Localized strings (in plugin directory)


### Renamed Files (case change)
- `plugin/bin/*` → `plugin/Bin/*` - Standardized directory name capitalization

## Performance Considerations

### Version Caching
- Version checked only once per hour (3600s TTL)
- Reduces repeated `--version` calls
- Cache cleared immediately after update
- Prevents stale version display

### Update Polling
- Only active during updates (2s intervals)
- Stops automatically on completion or timeout
- Minimal HTTP overhead (fetches only HTML page)
- No database queries involved

### Server Load
- Non-blocking process execution
- Timer-based polling adds negligible CPU
- Cache operations are fast (in-memory)
- Single background process per update

## Troubleshooting

### Update button doesn't work
- **Check**: JavaScript console for errors
- **Test**: Disable JavaScript and verify button still submits form
- **Verify**: Browser supports XMLHttpRequest

### Status doesn't update automatically
- **Check**: Network tab shows AJAX requests every 2 seconds
- **Verify**: Requests return 200 status
- **Test**: Manual page refresh shows updated status
- **Debug**: Server logs show `_checkUpdateProgress()` calls

### Update times out
- **Symptom**: "Update taking longer than expected" message
- **Reason**: Slow network or large download
- **Solution**: Increase `UPDATE_MAX_CHECKS` in Settings.pm
- **Note**: Process continues in background even after timeout

### Permission errors (Unix)
- **Symptom**: "Failed to set write permission"
- **Check**: Binary file location is writable
- **Check**: LMS user has write access to directory
- **Check**: SELinux/AppArmor not blocking chmod
- **Fix**: Move binary to writable location or adjust permissions

### Output file not found
- **Symptom**: Warning in logs but update succeeds
- **Reason**: Shell redirection failed
- **Check**: Cache directory is writable
- **Check**: Disk space available
- **Impact**: Status relies on exit code only (still works)

### Version shows "N/A" or "Unknown"
- **Symptom**: Current version displays "N/A" or "Unknown"
- **Reason**: Cannot parse `--version` output
- **Check**: Binary is executable
- **Check**: Binary is not corrupted
- **Fix**: Re-download binary or select different version

## Testing Checklist

- [x] Version displays correctly on page load
- [x] Version is cached (logs show check once per hour)
- [x] Button shows "Updating..." when clicked
- [x] Wait cursor appears during update
- [x] AJAX polling updates status without page reload
- [x] Version number updates automatically on success
- [x] Button re-enables when complete
- [x] Unix: Permissions change 0555 → 0755 → 0555
- [x] Windows: Update executes without permission changes
- [x] Success message shows in green
- [x] "Already up to date" message shows in green
- [x] Error messages show in red
- [x] Cache cleanup happens after status display

## Future Enhancements

Possible improvements not currently implemented:

1. **Scheduled Updates**: Automatic updates once a day/week

## Known Limitations

1. **Maximum timeout**: Status checks stop after 30 seconds (process continues)
2. **No progress indicator**: Shows only "Updating..." until complete
3. **Requires page visit**: No background automatic updates
4. **No rollback**: Cannot revert to previous version automatically
5. **Temp file cleanup**: May leave temp files on abrupt process termination
