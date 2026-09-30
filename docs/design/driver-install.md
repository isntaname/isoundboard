# Bundled audio driver

iSoundboard needs a virtual audio device: it plays into the device, and the
game records from it. Today users install BlackHole 2ch themselves. This
design ships our own build of BlackHole inside the app and installs it on
first launch, so the whole install is one download.

## Goals

- Install is: download the DMG, drag to Applications, open, click
  **Install Audio Driver**, enter the Mac password once.
- Updating the app can update the driver; the driver can be uninstalled from
  Settings.
- Anyone who already uses BlackHole 2ch keeps working with no prompts.

Not in scope: Developer ID signing, notarization, Homebrew, Steam.

## Licensing

iSoundboard is GPL-3.0, which is what BlackHole's authors require for
building it into another project. We build from source and ship under our own
name. BlackHole's name, icon and official binaries are not used. The app
bundle includes BlackHole's LICENSE, and the README credits it: "Audio driver
based on BlackHole by Existential Audio".

## Feasibility (tested 2026-09-30)

On this Mac (macOS 26.4.1), BlackHole's source was built as a 2-channel
driver named "iSoundboard" and signed with an Apple Development certificate
(no Developer ID). It was installed to `/Library/Audio/Plug-Ins/HAL` and Core
Audio was restarted. The result:

- `soundboardctl devices` listed `iSoundboard [in:2 out:2] 48000Hz iSoundboard_UID`,
  alongside BlackHole 2ch.
- `soundboardctl verify "iSoundboard"`: a 440 Hz tone reached the device and
  was recorded back at the right pitch. PASS.

Not yet tested: a copy downloaded with the quarantine flag (the installer
clears the flag, see below), and a second Mac.

## Components

### 1. Driver source: `Driver/BlackHole/`

- BlackHole v0.7.1 (tag commit `e2b22aa`), vendored: `BlackHole/`,
  `BlackHole.xcodeproj`, `BlackHoleTests/`, `LICENSE`, `README.md`,
  `CHANGELOG.md`, `VERSION`. Their installer, uninstaller and images are left out.
- `Driver/README.md` records the origin, the commit, and our changes.
- Our changes are applied at build time, not by editing the vendored files.
  That keeps updating to a newer BlackHole to "replace the folder".

### 2. Driver build: `Driver/build-driver.sh`, called by `build-app.sh`

It runs `xcodebuild` with these settings:

| Setting | Value |
|---|---|
| Architectures | `arm64 x86_64` |
| `PRODUCT_NAME` | `iSoundboard` |
| Bundle id | `io.github.isntaname.isoundboard.driver` |
| `kDriver_Name`, `kDevice_Name` | `"iSoundboard"` |
| `kHas_Driver_Name_Format` | `false`, so the device is `iSoundboard`, not `iSoundboard 2ch` |
| `kManufacturer_Name` | `"iSoundboard"` |
| `kPlugIn_Icon` | `"iSoundboard.icns"` |
| `kNumber_Of_Channels` | `2` |

Two strings are hard-coded in `BlackHole.c` rather than set by macros:
`CFSTR("BlackHole Box")` and the box's `CFSTR("Existential Audio Inc.")`. The
script patches a temporary copy of the source to use `kDriver_Name " Box"` and
`kManufacturer_Name`. The copyright header is left intact.

After the build, the script:

- Removes `BlackHole.icns`, `README.md` and `CHANGELOG.md` from the bundle, and
  adds `Resources/Icon/AppIcon.icns` as `iSoundboard.icns`. `LICENSE` stays.
- Sets `CFBundleVersion` to `<BlackHole version>.<DRIVER_REVISION>`, e.g.
  `0.7.1.1`. `DRIVER_REVISION` is a number in the script, bumped whenever our
  build of the driver changes.
- Skips the build when the output is newer than every input, so ordinary app
  rebuilds stay fast.

`build-app.sh` copies the result to
`iSoundboard.app/Contents/Library/Driver/iSoundboard.driver` and signs it
before signing the app (nested code first, no `--deep`).

### 3. `DriverInstaller` (new, in `AudioEngine`)

Pure logic, unit-tested:

- `status(installed: Bundle?, bundled: Bundle) -> .notInstalled | .current | .outdated`.
  The comparison is on `CFBundleVersion`. "Different" counts as outdated, so
  downgrading to an older app also replaces the driver.
- `installScript(from: URL) -> String` and `uninstallScript() -> String` build
  the shell commands. Paths are single-quoted, with embedded quotes escaped.

It also runs those scripts:

- `install()` runs one privileged shell command through `NSAppleScript`
  (`do shell script … with administrator privileges with prompt "iSoundboard
  needs your password to install its audio driver."`). The command:
  1. Copy the bundled driver with `ditto` into a root-only temporary
     folder, and refuse it if it is a symlink.
  2. `codesign --verify --strict` the copy against a pinned requirement: our
     bundle id, signed by the same team as the running app (read from the
     app's in-memory signature). The app bundle is user-writable, so this
     stops anything running as the user from swapping in its own code during
     the password prompt.
  3. `xattr -cr` and `chown -R root:wheel` on the copy.
  4. Replace the installed driver with it (`mv`), then `killall coreaudiod`.
     A failed check leaves the old driver in place.
- `uninstall()` removes the installed copy, then runs `killall coreaudiod`.
- If the user clicks Cancel in the password prompt, it returns a `.cancelled`
  result. That is not an error and shows no message.

### 4. Device choice (`AppModel.refreshDevices`)

The current fallback takes the first device that can both play and record,
which can pick a USB headset. It becomes:

1. The saved `virtualUID`, if that device is present.
2. `iSoundboard_UID`.
3. `BlackHole2ch_UID`.
4. Otherwise nothing, and setup shows the install button.

### 5. UI

**Setup screen**, for the virtual-device requirement:

- Title: "Audio driver".
- Detail: "The game hears iSoundboard through it."
- Button: **Install Audio Driver**.
- While installing, the button shows a spinner and is disabled. On failure,
  the error text appears as a warning caption.

**Settings → What the game hears:** the existing device row stays. Below it:

- If no virtual device is found: **Install Audio Driver**. The app opens on
  Settings while setup is incomplete, so the button has to be here too.
- If our driver is outdated: an **Update Audio Driver** button.
- If our driver is installed: **Uninstall Audio Driver**, as a destructive,
  link-style button. Before removing, the app restores the previous system
  microphone.
- If the device in use is BlackHole: neither button.

**Status texts** that say "install BlackHole" now point to the install
button instead.

Restarting `coreaudiod` drops every audio device for a second or two. The
engine already rebuilds on device changes, and the health poll covers the
gap. After an install, the app selects the new device and claims the system
microphone as usual.

### 6. Docs

- **README Install section** becomes:
  1. Download the DMG and drag iSoundboard to Applications.
  2. Open it, then Open Anyway.
  3. Click **Install Audio Driver**.
  4. Grant permissions.

  The BlackHole install step goes away. It also gains an uninstall note and
  the BlackHole credit.
- **RELEASING.md:** building the driver needs full Xcode.

## Testing

- **Unit tests:**
  - Version comparison: not installed, same version, different version,
    missing `CFBundleVersion`.
  - Script quoting: paths with spaces and with `'`.
  - Device preference order.
- **Manual, on this Mac:**
  1. Remove the spike driver.
  2. Click Install: the device appears, and `soundboardctl verify "iSoundboard"`
     passes.
  3. Bump `DRIVER_REVISION` and rebuild: Update appears and works.
  4. Uninstall: the device is gone and the system microphone is restored.
  5. Cancel the password prompt: nothing changes and no error shows.
- **Before the first release:** install from a downloaded DMG on a second Mac.

## Risks

- **Downloaded copies.** macOS may refuse a driver that is still marked as
  downloaded. Mitigation: step 3 of the installer clears the flag. Verify on
  a second Mac.
- **Hardened runtime.** A future Developer ID build turns on the hardened
  runtime, which might affect `NSAppleScript` running a privileged command.
  Re-check when notarization is added. `SMAppService` is the fallback.
- **Stale driver.** Replacing the driver while an older app version is
  running is fine: the device's UID doesn't change.
