# YT-DLP Update Feature Implementation

## Overview

This implementation adds a self-update capability for the yt-dlp binary in the LMS-YouTube plugin settings interface. Users can view their currently installed yt-dlp version and update the binary directly from the plugin settings without manual intervention.

## Modified Files

### 1. basic.html (HTML/Settings Template)

**Location:** `plugin/HTML/EN/plugins/YouTube/settings/basic.html`

**Changes:**

* **Automatic Version Display:** Displays the current version immediately below the binary selector.
* **Single Action Button:** A "Update yt-dlp" button handles the update process.
* **Visual Feedback:** Added JavaScript to change the button text to "Updating..." and the cursor to 'wait' while the operation processes.
* **Status Messages:** Conditional display of success (green) or error (red) messages.

**Code Addition:**

```html
[% IF current_version %]
    <br><span style="color: #666; font-size: 0.9em;">[% "PLUGIN_YOUTUBE_CURRENT_VERSION" | string %]: <b>[% current_version %]</b></span>
    [% IF available_version && available_version != current_version %]
        <span style="color: orange; font-size: 0.9em;"> → [% "PLUGIN_YOUTUBE_AVAILABLE_VERSION" | string %]: <b>[% available_version %]</b></span>
    [% END %]
[% END %]
<br><br>
<script type="text/javascript">
    function showUpdateProgress(btn) {
        btn.value = 'Updating...';
        btn.style.cursor = 'wait';
    }
</script>

<input name="update_ytdlp" type="submit" value="[% 'PLUGIN_YOUTUBE_UPDATE_YTDLP' | string %]" onclick="showUpdateProgress(this)">

[% IF update_status %]
    <br><span style="[% IF update_error %]color: red;[% ELSE %]color: green;[% END %]">[% update_status %]</span>
[% END %]

```

### 2. Settings.pm (Perl Backend)

**Location:** `plugin/Settings.pm`

**Changes:**

* **`handler()`**:
* Calls `_getCurrentVersion` on every page load to populate the UI.
* Detects `update_ytdlp` parameter to trigger the update process.


* **`_getCurrentVersion()`**:
* Runs `yt-dlp --version`.
* **Caching:** Caches the result for 1 hour (3600 seconds) to prevent performance impact on repeated page loads.
* Clears cache immediately after an update or if `update_ytdlp` is triggered.


* **`_updateYtDlp()`**: Logic to determine OS and dispatch to specific handler.
* **`_updateYtDlpUnix()`**:
* Temporarily changes file permissions to `0755` (writable) to allow self-update.
* Uses `AnyEvent::Util::run_cmd` for execution.
* Restores permissions to `0555` (read-only) immediately after.


* **`_updateYtDlpWindows()`**:
* Uses a piped open to execute the update command.
* Merges STDERR into STDOUT for complete log capture.



### 3. Utils.pm (Utility Functions)

**Location:** `plugin/Utils.pm`

**New Functions Added:**

* `set_yt_dlp_writable($bin_path)`: Sets permissions to 0755 (rwxr-xr-x) for self-update.
* `set_yt_dlp_readonly($bin_path)`: Restores permissions to 0555 (r-xr-xr-x) for security.

**Permission Management Strategy:**

* **Default state**: Binary has 0555 permissions (read + execute only).
* **During update**: Temporarily elevated to 0755 (read + write + execute for owner).
* **After update**: Restored to 0555 (prevents accidental modification).
* **Windows**: No permission changes needed (Windows handles this differently).

### 4. strings.txt (Localization)

**Location:** `plugin/strings.txt`

**Added Strings:**

* `PLUGIN_YOUTUBE_UPDATE_YTDLP` - Update button label
* `PLUGIN_YOUTUBE_CURRENT_VERSION` - Current version label
* `PLUGIN_YOUTUBE_AVAILABLE_VERSION` - Available version label
* `PLUGIN_YOUTUBE_VERSION_UP_TO_DATE` - Up to date message
* `PLUGIN_YOUTUBE_UPDATE_SUCCESS` - Success message
* `PLUGIN_YOUTUBE_UPDATE_FAILED` - Failure message
* `PLUGIN_YOUTUBE_UPDATE_ERROR` - Error message
* `PLUGIN_YOUTUBE_UPDATE_BINARY_NOT_FOUND` - Binary not found error

## Usage

1. Navigate to Settings → Plugins → YouTube.
2. Locate the "YT-dlp url extractor" section.
3. **View Current Version**: The installed version (e.g., `2023.03.04`) is displayed automatically below the dropdown.
4. **Update yt-dlp**:
* Click the **"Update yt-dlp"** button.
* The button text will change to "Updating...".
* The page will reload.


5. **Verify Result**:
* A message will appear indicating success ("Update successful", "Up to date") or failure.
* The "Current version" display will update to reflect the new version.



## Technical Details

### Update Process Flow:

1. **On Page Load**:
* `_getCurrentVersion` checks the cache (`yt:version:binary_name`).
* If not cached, it runs `binary --version`, parses the output, and caches it for 1 hour.


2. **Update Button Clicked**:
* `Settings.pm` detects `update_ytdlp` param.
* **[Unix/Linux/macOS]**:
* Permissions set to **0755**.
* Command `binary -U` executed via `AnyEvent::Util`.
* Permissions restored to **0555**.


* **[Windows]**:
* Command `binary -U` executed via system shell.


* **Post-Update**:
* Output is parsed for "up to date" or success messages.
* The version cache is cleared to force a refresh on the reloaded page.





### Error Handling:

* **Binary not found**: Returns specific error string.
* **Permission Errors**: If `chmod` fails, the update is aborted and logged.
* **Execution Errors**: Caught via `eval` blocks; exceptions are logged and displayed in the UI (red text).

### Security Considerations

* **Read-Only Default**: The binary is kept read-only (0555) during normal operation to prevent tampering.
* **Temporary Escalation**: Write permissions are only granted for the exact duration of the update command.
* **Safe Restoration**: The `finally` logic (implemented via `set_yt_dlp_readonly`) attempts to restore safe permissions even if the update crashes.

## Dependencies

### Perl Modules Required:

* **Unix/Linux/macOS:** `AnyEvent::Util` (Standard LMS dependency).
* **All Systems:** Standard Perl core modules (`File::Spec`, `List::Util`).

## Testing Checklist

* [x] Current version displays on page load.
* [ ] Version is cached (logs show "Current yt-dlp version: ..." only once per hour unless updated).
* [x] Update button changes visual state (JavaScript).
* [x] Unix: Permissions flip 0755 -> Update -> 0555.
* [ ] Windows: Update command executes correctly via piped open.
* [x] Success/Error messages render correctly in the template.
