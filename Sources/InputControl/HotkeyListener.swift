import CoreGraphics
import Foundation

/// Watches the keyboard system-wide without consuming anything.
///
/// Listen-only is not an optimisation, it is a requirement: consuming the event
/// would stop the key reaching the game, which breaks both normal play and the
/// mode where the soundboard key IS the game's push-to-talk key.
public final class HotkeyListener: @unchecked Sendable {

    public struct Event: Sendable {
        public let trigger: Trigger
        public let modifiers: KeyModifiers
        public let isDown: Bool
        /// Hardware events report process id 0; anything else was synthesized
        /// — including our own push-to-talk, which must not retrigger sounds.
        public let isSynthetic: Bool
    }

    public var onEvent: (@Sendable (Event) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public private(set) var isRunning = false

    public init() {}

    deinit { stop() }

    public enum ListenerError: Error, CustomStringConvertible {
        case tapCreationFailed

        public var description: String {
            "Could not watch the keyboard — grant Input Monitoring, then restart the app."
        }
    }

    public func start() throws {
        guard !isRunning else { return }

        // Middle and side mouse buttons too — push-to-talk is often Mouse 4 or 5.
        // Left and right click are deliberately excluded: binding them would
        // make the machine unusable.
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(context).takeUnretainedValue()
                listener.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: context)
        else { throw ListenerError.tapCreationFailed }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        self.tap = nil
        runLoopSource = nil
        isRunning = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap that takes too long; without re-arming it,
        // hotkeys stop working silently partway through a session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let trigger: Trigger
        let isDown: Bool

        switch type {
        case .keyDown, .keyUp:
            trigger = .key(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            isDown = type == .keyDown
        case .otherMouseDown, .otherMouseUp:
            trigger = .mouseButton(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
            isDown = type == .otherMouseDown
        default:
            return
        }

        onEvent?(Event(
            trigger: trigger,
            modifiers: KeyModifiers(flags: event.flags),
            isDown: isDown,
            isSynthetic: event.getIntegerValueField(.eventSourceUnixProcessID) != 0))
    }
}
