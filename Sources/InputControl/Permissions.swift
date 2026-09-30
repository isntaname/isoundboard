import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The three TCC services this app needs.
///
/// Two things about macOS make this harder than it looks:
///
/// 1. **Input Monitoring cannot be prompted for on macOS 26.** Every available
///    call — `CGRequestListenEventAccess`, `IOHIDRequestAccess`, and creating an
///    event tap — reaches tccd as `preflight=yes`, a query that never shows a
///    dialog, even after `tccutil reset`. The user must add the app by hand with
///    the "+" button in System Settings, so the UI has to guide that rather than
///    offer a button that silently does nothing.
/// 2. TCC attributes permission to the *responsible process*. Launching the
///    binary from a terminal makes the app inherit the terminal's grants, so it
///    never prompts and reports permissions it does not really have. The app
///    must be launched through LaunchServices (`open`) to get its own identity.
public enum Permission: String, CaseIterable, Sendable {
    case microphone = "Microphone"
    case inputMonitoring = "Input Monitoring"
    case accessibility = "Accessibility"

    public var why: String {
        switch self {
        case .microphone: return "Mix your real voice into the virtual mic"
        case .inputMonitoring: return "Notice your hotkeys while a game is focused"
        case .accessibility: return "Send the push-to-talk keypress to the game"
        }
    }

    public var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .accessibility: return AXIsProcessTrusted() && CGPreflightPostEventAccess()
        }
    }

    /// Whether macOS will actually show a dialog for this permission.
    /// Only Microphone and Accessibility do; Input Monitoring never does.
    public var canPrompt: Bool {
        switch self {
        case .microphone, .accessibility: return true
        case .inputMonitoring: return false
        }
    }

    /// What the user has to do, in plain words.
    public var instruction: String {
        switch self {
        case .microphone:
            return "Allow the microphone prompt."
        case .accessibility:
            return "Allow the prompt, or switch iSoundboard on in Settings."
        case .inputMonitoring:
            return "macOS never prompts for this one. In Settings, click + and choose iSoundboard.app, then relaunch."
        }
    }

    /// Ask macOS to show the system prompt.
    ///
    /// Must run on the main thread with the app frontmost, or the dialog can
    /// fail to appear.
    @MainActor
    public func request() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        switch self {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }

        case .inputMonitoring:
            // Two triggers, because either can be the one that surfaces the
            // dialog depending on the app's prior TCC history.
            _ = CGRequestListenEventAccess()
            _ = Self.probeEventTap()

        case .accessibility:
            _ = CGRequestPostEventAccess()
            // The imported constant is a global `var`, which Swift 6 rejects as
            // shared mutable state. Its value is this fixed string (verified at
            // runtime against kAXTrustedCheckOptionPrompt).
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    /// Attempt a listen-only tap. Returns whether it succeeded; the attempt
    /// itself is one of the things that can trigger the Input Monitoring prompt.
    @discardableResult
    public static func probeEventTap() -> Bool {
        let mask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil)
        else { return false }

        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }

    public func openSettings() {
        guard let url = URL(string: settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Show the app in Finder so it can be dragged into the Settings list.
    /// The "+" picker does not show hidden build folders, so this is the
    /// quickest reliable route.
    public static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    public var settingsURL: String {
        switch self {
        case .microphone: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .inputMonitoring: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
    }
}

public enum LaunchContext {
    /// True when the binary was run straight from a shell rather than through
    /// LaunchServices. In that case TCC reports the terminal's permissions, so
    /// anything the app believes about its own access is misleading.
    public static var isRunningFromTerminal: Bool {
        // Checking TERM or isatty does NOT work: `open` passes the shell's
        // environment straight through, so both look identical.
        //
        // The parent process does discriminate. LaunchServices reparents the
        // app to launchd (pid 1); a binary exec'd from a shell keeps the shell
        // as its parent.
        getppid() != 1
    }
}
