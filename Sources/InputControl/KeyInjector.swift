import AppKit
import CoreGraphics
import Foundation

/// Holds down the game's push-to-talk key while a clip plays, so the clip is
/// actually transmitted.
///
/// Posts to the HID tap with a `hidSystemState` source — the most
/// hardware-like of the available routes, and the one confirmed to flip the
/// HID key-state table, which is what a polling game reads.
///
/// Whether a given game honours a synthesized key is its own decision; macOS
/// marks these events as synthetic and some games filter them. `selfTest()`
/// reports whether the system registered the press, which is as far as we can
/// check without the game running.
public struct KeyInjector: Sendable {

    /// What the game has bound to push-to-talk — a key or a mouse button.
    public var trigger: Trigger
    /// Set false to inject nothing and hold push-to-talk yourself.
    public var isEnabled: Bool

    public init(trigger: Trigger = .key(9), isEnabled: Bool = true) {
        self.trigger = trigger
        self.isEnabled = isEnabled
    }

    private var source: CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    public func pressDown() { send(down: true) }
    public func release() { send(down: false) }

    private func send(down: Bool) {
        guard isEnabled else { return }

        switch trigger {
        case let .key(code):
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            else { return }
            event.post(tap: .cghidEventTap)

        case let .mouseButton(button):
            // Post at the cursor's current position, or the click would also
            // warp the pointer to the origin.
            let location = CGEvent(source: nil)?.location ?? .zero
            guard let mouseButton = CGMouseButton(rawValue: UInt32(button)),
                  let event = CGEvent(mouseEventSource: source,
                                      mouseType: down ? .otherMouseDown : .otherMouseUp,
                                      mouseCursorPosition: location,
                                      mouseButton: mouseButton)
            else { return }
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            event.post(tap: .cghidEventTap)
        }
    }

    /// Does a synthesized press register in the HID key-state table? This is
    /// what a polling game reads, and it can be checked without the game.
    /// Does a synthesized press register in the HID state table? Keys only —
    /// there is no equivalent query for mouse buttons.
    public func selfTest() -> Bool {
        guard isEnabled, case let .key(code) = trigger else { return false }
        pressDown()
        Thread.sleep(forTimeInterval: 0.12)
        let held = CGEventSource.keyState(.hidSystemState, key: code)
        release()
        return held
    }
}
