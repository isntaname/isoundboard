// pttprobe — Milestone 0 throwaway spike.
//
// Answers one question: can we open a game's push-to-talk by synthesizing a
// keypress on macOS 26, or does the game (or WindowServer) filter it out?
//
// THIS CODE IS NOT KEPT. Its output is an answer, not a component.

import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

// MARK: - Key names

// Only the keys people actually bind to push-to-talk.
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "b": 11, "c": 8, "f": 3, "g": 5, "h": 4, "j": 38, "k": 40,
    "m": 46, "n": 45, "t": 17, "v": 9, "x": 7, "z": 6,
    "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64,
    "capslock": 57, "grave": 50, "tab": 48, "space": 49,
    "leftalt": 58, "leftctrl": 59, "leftshift": 56,
    "mouse4": 0xFFFF, // sentinel, unsupported — listed so the error is clear
]

func keyCode(for name: String) -> CGKeyCode? {
    let k = keyCodes[name.lowercased()]
    return k == 0xFFFF ? nil : k
}

// MARK: - Permissions

func reportPermissions() {
    let ax = AXIsProcessTrusted()
    let post = CGPreflightPostEventAccess()
    let listen = CGPreflightListenEventAccess()

    print("  TCC permissions (all three are queried independently):")
    print("    kTCCServiceAccessibility : \(ax ? "granted" : "DENIED")")
    print("    kTCCServicePostEvent     : \(post ? "granted" : "DENIED")")
    print("    kTCCServiceListenEvent   : \(listen ? "granted" : "DENIED")")

    if !ax || !post || !listen {
        print("""

              ! Grant these to the app you are running this FROM (Terminal/iTerm),
              ! not to pttprobe — TCC attributes permission to the responsible process.
              !   System Settings > Privacy & Security > Accessibility
              !   System Settings > Privacy & Security > Input Monitoring
              ! Then fully quit and reopen the terminal.
              """)
    }
}

// MARK: - Injection methods

enum Method: String, CaseIterable {
    case hid          // CGEventPost(.cghidEventTap) + .hidSystemState source
    case session      // CGEventPost(.cgSessionEventTap)
    case annotated    // CGEventPost(.cgAnnotatedSessionEventTap)
    case combined     // .combinedSessionState source, HID tap
    case privateState // .privateState source, HID tap
    case pid          // CGEventPostToPid(targetPID)

    var summary: String {
        switch self {
        case .hid:          return "CGEventPost -> .cghidEventTap, source .hidSystemState (most 'hardware-like')"
        case .session:      return "CGEventPost -> .cgSessionEventTap"
        case .annotated:    return "CGEventPost -> .cgAnnotatedSessionEventTap"
        case .combined:     return "CGEventPost -> .cghidEventTap, source .combinedSessionState"
        case .privateState: return "CGEventPost -> .cghidEventTap, source .privateState"
        case .pid:          return "CGEventPostToPid(<pid>) — bypasses some session filtering"
        }
    }
}

func source(for method: Method) -> CGEventSource? {
    switch method {
    case .combined:     return CGEventSource(stateID: .combinedSessionState)
    case .privateState: return CGEventSource(stateID: .privateState)
    default:            return CGEventSource(stateID: .hidSystemState)
    }
}

func post(_ event: CGEvent, method: Method, pid: pid_t) {
    switch method {
    case .session:   event.post(tap: .cgSessionEventTap)
    case .annotated: event.post(tap: .cgAnnotatedSessionEventTap)
    case .pid:       event.postToPid(pid)
    default:         event.post(tap: .cghidEventTap)
    }
}

/// Press and hold a key, then release it.
func holdKey(_ code: CGKeyCode, method: Method, pid: pid_t, seconds: Double) {
    let src = source(for: method)

    guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
          let up   = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    else {
        print("    ! failed to construct CGEvent")
        return
    }

    post(down, method: method, pid: pid)
    Thread.sleep(forTimeInterval: seconds)
    post(up, method: method, pid: pid)
}

// MARK: - Listen-only tap

// C callbacks can't capture, so the tap handle lives here.
var listenTap: CFMachPort?

/// Set by selftest: only report synthesized events, never the user's real typing.
var syntheticOnly = false
/// keycodes observed from synthetic sources, for selftest assertions.
var observedSynthetic: [Int64] = []
let observedLock = NSLock()

func installTap() -> Bool {
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

    let callback: CGEventTapCallBack = { _, type, event, _ in
        // Re-arm if the system disabled us for being slow.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = listenTap { CGEvent.tapEnable(tap: tap, enable: true) }
            print("  (tap was disabled, re-enabled)")
            return Unmanaged.passUnretained(event)
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // Was this event synthesized, or did it come from real hardware?
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        let origin = pid == 0 ? "hardware" : "synthetic (pid \(pid))"
        let name = keyCodes.first { $0.value == CGKeyCode(code) }?.key ?? "?"

        if pid != 0 {
            observedLock.lock(); observedSynthetic.append(code); observedLock.unlock()
        } else if syntheticOnly {
            // Don't log the user's real keystrokes.
            return Unmanaged.passUnretained(event)
        }

        print("  \(type == .keyDown ? "DOWN" : "UP  ") keycode \(code) (\(name)) — \(origin)")
        return Unmanaged.passUnretained(event)
    }

    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                      place: .headInsertEventTap,
                                      options: .listenOnly,   // never consume — game must still get the key
                                      eventsOfInterest: CGEventMask(mask),
                                      callback: callback,
                                      userInfo: nil) else {
        return false
    }

    listenTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

func runListener() {
    print("  Listen-only CGEventTap at .cghidEventTap.")
    print("  Focus your game FULLSCREEN and press keys. Ctrl-C to stop.")
    print("  If keycodes appear while the game is focused, hotkeys work in-game.\n")
    guard installTap() else {
        print("  ! tapCreate failed — Input Monitoring is not granted."); exit(1)
    }
    CFRunLoopRun()
}

/// Fires each method and checks whether our own event tap observed it.
/// Validates the probe before we trust a negative result from a game.
func runSelfTest(_ code: CGKeyCode) {
    syntheticOnly = true
    print("  Self-test: does each method produce an event the system actually sees?")
    print("  (Your real keystrokes are NOT logged in this mode.)\n")

    guard installTap() else {
        print("  ! tapCreate failed — Input Monitoring is not granted."); exit(1)
    }

    var results: [(Method, Bool)] = []
    for method in Method.allCases where method != .pid {
        observedLock.lock(); observedSynthetic.removeAll(); observedLock.unlock()

        holdKey(code, method: method, pid: 0, seconds: 0.05)
        // Let the tap drain.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        observedLock.lock()
        let seen = observedSynthetic.contains(Int64(code))
        observedLock.unlock()
        results.append((method, seen))
        print("    \(seen ? "OBSERVED" : "not seen") — \(method.rawValue)")
    }

    print("\n  Interpretation:")
    print("    'OBSERVED' = the event reached the HID event stream. A game MAY still")
    print("    reject it, but the probe works. 'not seen' at .cghidEventTap is expected")
    print("    for session/annotated methods, which insert downstream of the HID tap.\n")
    // Many games poll key state rather than consume events. If a synthetic
    // keyDown flips the HID key-state table, polling games see the key held.
    print("  Key-state table check (what a polling game reads):")
    guard let s = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: s, virtualKey: code, keyDown: true),
          let up   = CGEvent(keyboardEventSource: s, virtualKey: code, keyDown: false) else { return }

    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.15)
    let hidHeld      = CGEventSource.keyState(.hidSystemState,      key: code)
    let combinedHeld = CGEventSource.keyState(.combinedSessionState, key: code)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.15)
    let released     = !CGEventSource.keyState(.hidSystemState,     key: code)

    print("    held in .hidSystemState      : \(hidHeld ? "YES" : "no")")
    print("    held in .combinedSessionState: \(combinedHeld ? "YES" : "no")")
    print("    released cleanly             : \(released ? "YES" : "NO — key may be stuck!")")
    if hidHeld {
        print("    => polling-based games should register this as a held key.\n")
    } else {
        print("    => polling games will NOT see this. Tier C is unlikely to work.\n")
    }

    let anyWorked = results.contains { $0.1 }
    print(anyWorked ? "  Probe is functional — negatives against a game are real findings.\n"
                    : "  ! Nothing observed at all. Fix the probe before testing a game.\n")
}

// MARK: - Target lookup

func findPID(matching name: String) -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first { ($0.localizedName ?? "").lowercased().contains(name.lowercased()) }?
        .processIdentifier
}

func countdown(_ seconds: Int, _ message: String) {
    print("  \(message)")
    for i in stride(from: seconds, to: 0, by: -1) {
        print("    \(i)...", terminator: "\n")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
    }
}

// MARK: - Main

let args = CommandLine.arguments
let usage = """
pttprobe — does synthetic push-to-talk actually reach the game?

  pttprobe selftest [key]
      Verify the probe works before trusting it. Fires each method and
      checks the system saw it. Does not log your real keystrokes.

  pttprobe listen
      Listen-only event tap. Confirms hotkeys are visible while a
      fullscreen game has focus, and labels each event hardware/synthetic.

  pttprobe press <key> [method] [hold] [app]
      Fire one keypress.  method: \(Method.allCases.map(\.rawValue).joined(separator: " | "))
      e.g.  pttprobe press v hid 2 Dota

  pttprobe sweep <key> [app]
      Try EVERY method in turn with spoken countdowns, so a single
      game session tests all of them. This is the main event.

  keys: \(keyCodes.keys.sorted().joined(separator: " "))
"""

guard args.count > 1 else { print(usage); exit(0) }

print("\n=== pttprobe (M0 spike) ===\n")
reportPermissions()
print("")

switch args[1] {
case "listen":
    runListener()

case "selftest":
    runSelfTest(keyCode(for: args.count > 2 ? args[2] : "f13") ?? 105)

case "press":
    guard args.count > 2, let code = keyCode(for: args[2]) else {
        print("! unknown key\n"); print(usage); exit(1)
    }
    let method = Method(rawValue: args.count > 3 ? args[3] : "hid") ?? .hid
    let hold   = Double(args.count > 4 ? args[4] : "2") ?? 2
    let appName = args.count > 5 ? args[5] : "Dota"
    let pid = findPID(matching: appName) ?? 0

    if method == .pid && pid == 0 {
        print("! no running app matching '\(appName)' — needed for the pid method."); exit(1)
    }

    print("  method: \(method.rawValue) — \(method.summary)")
    if pid != 0 { print("  target: \(appName) (pid \(pid))") }
    countdown(5, "Focus the game and hold nothing. Firing '\(args[2])' for \(hold)s:")
    holdKey(code, method: method, pid: pid, seconds: hold)
    print("  done — did the game's mic open?\n")

case "sweep":
    guard args.count > 2, let code = keyCode(for: args[2]) else {
        print("! unknown key\n"); print(usage); exit(1)
    }
    let appName = args.count > 3 ? args[3] : "Dota"
    let pid = findPID(matching: appName) ?? 0
    print("  target app: \(appName) — \(pid == 0 ? "NOT RUNNING (pid method will be skipped)" : "pid \(pid)")")
    countdown(8, "Focus the game now. Watch the voice indicator for each method.")

    for method in Method.allCases {
        if method == .pid && pid == 0 { continue }
        print("\n  --> \(method.rawValue): \(method.summary)")
        Thread.sleep(forTimeInterval: 1)
        holdKey(code, method: method, pid: pid, seconds: 2.5)
        print("      fired. 3s until next.")
        Thread.sleep(forTimeInterval: 3)
    }
    print("\n  Sweep complete. Note which method(s) opened the mic.\n")

default:
    print(usage)
}
