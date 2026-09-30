# macOS permission findings

Why the app appeared to have permissions it did not have, and why no prompt
showed up.

## 1. TCC follows the *responsible process*, not the binary

Running the app's binary straight from a shell makes macOS attribute permission
to the **terminal**. The same app, launched two ways:

| | `./Soundboard.app/Contents/MacOS/Soundboard` | `open Soundboard.app` |
|---|---|---|
| `AXIsProcessTrusted()` | true | **false** |
| `CGPreflightListenEventAccess()` | true | **false** |
| `CGEvent.tapCreate` | succeeded | **FAILED (nil)** |

The left column is the terminal's grants, not the app's. So a shell-launched
build never prompts, and anything it reports about its own access is misleading.
**Always launch with `open`.** Any verification done by exec'ing the binary is
measuring the wrong process.

## 2. Detecting that reliably: use the parent process

`isatty()` and `$TERM` do **not** work — `open` passes the shell environment
straight through, so both launch methods look identical. The parent process does
discriminate:

- launched via `open` → reparented to **launchd, pid 1**
- exec'd from a shell → parent is **zsh**

So `getppid() != 1` means "started from a terminal".

## 3. Input Monitoring cannot be prompted for at all on macOS 26

There is no API that produces the Input Monitoring dialog. Every candidate was
tried against a freshly-reset bundle, with the app launched by LaunchServices,
frontmost, fully launched, and kept alive 20s:

| Attempt | Result |
|---|---|
| `CGRequestListenEventAccess()` | false, no dialog |
| `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` | false, no dialog |
| `CGEvent.tapCreate` (listen-only, HID tap) | nil, no dialog |
| after `tccutil reset ListenEvent <bundle>` | unchanged |
| signed ad-hoc vs. real Apple Development cert | unchanged |
| called during init vs. after `didFinishLaunching` + 1s | unchanged |

`tccd` logging shows why — every one arrives as a **query, not a request**:

```
AUTHREQ_CTX: service=kTCCServiceListenEvent, preflight=yes, query=1
```

`preflight=yes` never shows a dialog, and `IOHIDCheckAccess` reports `1`
(denied) rather than "unknown". So the user must add the app by hand via the
**+** button in System Settings. The UI must say that outright; a "Grant" button
here would do nothing at all.

Microphone (`AVCaptureDevice.requestAccess`) and Accessibility
(`AXIsProcessTrustedWithOptions`) do still prompt — hence `Permission.canPrompt`,
so the UI only offers the button where it means something.

Installing to `/Applications` matters for this: the **+** picker opens there, and
a build folder is awkward to reach.

## 3b. Don't read permission state in a SwiftUI view body

`Permission.isGranted` reads the system, which SwiftUI cannot observe — so the
section renders once and then never updates, including after the user returns
from System Settings. Keep it in observable state, refreshed on a timer and on
`NSApplication.didBecomeActiveNotification`.

## 4. Ad-hoc signatures invalidate grants on every rebuild

macOS ties these grants to the app's code identity. An ad-hoc signature is
identified by its hash, which changes with every build, so each rebuild is a new
app as far as TCC is concerned. The failure mode is nasty: **the app still shows
in System Settings with its checkbox ticked, while the tap silently fails.**

Detected in-app by `hasStaleAuthorization` (permission reports granted, yet
`tapCreate` fails) so the UI can say to remove and re-add the entry.

Fix properly by signing with a stable certificate:

```bash
export SOUNDBOARD_SIGN_IDENTITY="Apple Development: you@example.com"
./build-app.sh
```

Create one in Keychain Access → Certificate Assistant → Create a Certificate
(type: Code Signing, self-signed).

## 5. Event taps pick up the grant only at launch

Granting Input Monitoring while the app runs does not revive an existing failed
tap in a reliable way, so the app retries in the background and offers a
Relaunch button.

## 6. `kAXTrustedCheckOptionPrompt` under Swift 6

The imported constant is a global `var`, which strict concurrency rejects. Its
value is the fixed string `"AXTrustedCheckOptionPrompt"` (verified at runtime).
