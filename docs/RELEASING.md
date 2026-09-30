# Releasing

## Now: unsigned by Apple

```bash
VERSION=1.0.0 ./make-dmg.sh
git tag v1.0.0 && git push origin v1.0.0
```

Then create a GitHub release for the tag and attach `build/iSoundboard-1.0.0.dmg`.
The build is universal (Apple silicon and Intel).
Building needs full Xcode, not just the command line tools: the driver is an
Xcode project.

After publishing, run **Clean-machine install test** from the Actions tab. It
installs the release on a fresh Mac the way a user gets it and checks that the
driver loads and carries audio.

The app is signed with whatever certificate `build-app.sh` finds. That keeps
permission grants stable across updates, but Gatekeeper accepts neither an
Apple Development signature nor an ad-hoc one. Users have to click
**Open Anyway** once, as the README explains.

## Later: Developer ID and notarization

This needs an Apple Developer Program membership ($99/year). It removes the
Gatekeeper step and is required for the official Homebrew cask.

1. Create a **Developer ID Application** certificate.
2. Sign with the hardened runtime and the microphone entitlement:

   ```xml
   <!-- iSoundboard.entitlements -->
   <key>com.apple.security.device.audio-input</key><true/>
   ```

   ```bash
   codesign --force --options runtime --timestamp \
     --entitlements iSoundboard.entitlements \
     --sign "Developer ID Application: NAME (TEAMID)" build/iSoundboard.app
   ```

3. Build the DMG, sign it, notarize it and staple the ticket:

   ```bash
   codesign --timestamp --sign "Developer ID Application: NAME (TEAMID)" iSoundboard.dmg
   xcrun notarytool submit iSoundboard.dmg --key AuthKey.p8 --key-id KEY_ID --issuer ISSUER_ID --wait
   xcrun stapler staple iSoundboard.dmg
   ```

   Use an App Store Connect API key rather than an app-specific password.
   The key survives Apple ID password changes and can be revoked.

4. Move this into a GitHub Actions workflow triggered by `v*` tags, running on
   `macos-26`. Store the `.p12` and the API key as base64 repository secrets.

Input Monitoring and Accessibility have no entitlements. They're granted by
the user in System Settings either way.

## Homebrew

- **Own tap, possible now.** Create a repo named `homebrew-tap` with
  `Casks/isoundboard.rb`. Users install with
  `brew install --cask isntaname/tap/isoundboard`.
  - The cask can declare `depends_on cask: "blackhole-2ch"`, which installs the
    driver automatically.
  - Unnotarized apps still hit the Gatekeeper step.
- **Official homebrew/cask.** Needs a notarized app and a repo at least 30 days
  old. A self-submission by the author also needs 225 stars, 90 forks or 90
  watchers.

## BlackHole

iSoundboard is GPL-3.0, which is what BlackHole's authors require for
building it into another project. That lets us ship our own build of it,
compiled from source. Their official binaries and the BlackHole name and
branding still can't be used, so the bundled driver has its own name.
