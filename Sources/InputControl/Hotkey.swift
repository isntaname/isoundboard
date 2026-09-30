import CoreGraphics
import Foundation

public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)

    public init(flags: CGEventFlags) {
        var result: KeyModifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        self = result
    }

    public var symbols: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// What physically fires a hotkey. Push-to-talk is often a mouse side button,
/// so a bare key code is not enough.
public enum Trigger: Sendable, Hashable, Codable {
    case key(UInt16)
    /// CoreGraphics button number: 0 left, 1 right, 2 middle, 3+ side buttons.
    case mouseButton(Int)

    public var name: String {
        switch self {
        case let .key(code):
            return KeyCodes.name(for: code) ?? "key \(code)"
        case let .mouseButton(button):
            switch button {
            case 0: return "Left Click"
            case 1: return "Right Click"
            case 2: return "Middle Click"
            default: return "Mouse \(button + 1)"
            }
        }
    }
}

public struct Hotkey: Sendable, Hashable, Codable {
    public var trigger: Trigger
    public var modifiers: KeyModifiers

    public init(trigger: Trigger, modifiers: KeyModifiers = []) {
        self.trigger = trigger
        self.modifiers = modifiers
    }

    public init(keyCode: UInt16, modifiers: KeyModifiers = []) {
        self.init(trigger: .key(keyCode), modifiers: modifiers)
    }

    /// Hotkeys saved before mouse buttons existed stored a bare `keyCode`.
    /// Decoding has to accept both, or every existing binding silently clears.
    private enum CodingKeys: String, CodingKey {
        case trigger, modifiers, keyCode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try container.decodeIfPresent(KeyModifiers.self, forKey: .modifiers) ?? []

        if let trigger = try container.decodeIfPresent(Trigger.self, forKey: .trigger) {
            self.trigger = trigger
        } else {
            self.trigger = .key(try container.decode(UInt16.self, forKey: .keyCode))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(modifiers, forKey: .modifiers)
    }

    /// Does this event trigger the hotkey?
    ///
    /// A hotkey bound to a bare key must still fire while unrelated modifiers
    /// are held — in-game push-to-talk on a bare key has to work while the
    /// player is crouching with shift down. So the bound modifiers must be
    /// present, but extra ones are tolerated.
    public func matches(trigger: Trigger, modifiers held: KeyModifiers) -> Bool {
        self.trigger == trigger && held.isSuperset(of: modifiers)
    }

    public func matches(keyCode: UInt16, modifiers held: KeyModifiers) -> Bool {
        matches(trigger: .key(keyCode), modifiers: held)
    }

    public var displayName: String {
        modifiers.symbols + trigger.name
    }
}

/// What a keypress should do.
public enum HotkeyAction: Sendable, Hashable {
    /// Play the clip at this index in the board.
    case play(Int)
    case stopAll
}

public enum HotkeyMatcher {

    /// Route one keypress across the whole board, including the stop key.
    ///
    /// Stop is matched alongside the clips rather than ahead of them, so the
    /// most specific binding still wins: with stop on V and a clip on ⇧V,
    /// holding shift plays the clip instead of being swallowed by stop.
    ///
    /// A key bound to both a clip and stop plays the clip. That is a mistake
    /// the UI lets the user make, and resolving it the same way every time
    /// beats letting list order decide.
    public static func action(soundHotkeys: [Hotkey?],
                              stopHotkey: Hotkey?,
                              trigger: Trigger,
                              modifiers: KeyModifiers) -> HotkeyAction? {
        guard let index = bestMatch(soundHotkeys + [stopHotkey],
                                    trigger: trigger, modifiers: modifiers) else { return nil }
        return index == soundHotkeys.count ? .stopAll : .play(index)
    }

    /// Index of the hotkey that should fire for this keypress.
    ///
    /// A bare key deliberately matches while unrelated modifiers are held, so
    /// several hotkeys on the same key can match one press. The most specific
    /// one — the one requiring the most modifiers — is the one the user meant;
    /// without this, list order picks the winner and the wrong clip plays.
    public static func bestMatch(_ hotkeys: [Hotkey?],
                                 keyCode: UInt16,
                                 modifiers: KeyModifiers) -> Int? {
        bestMatch(hotkeys, trigger: .key(keyCode), modifiers: modifiers)
    }

    public static func bestMatch(_ hotkeys: [Hotkey?],
                                 trigger: Trigger,
                                 modifiers: KeyModifiers) -> Int? {
        var best: (index: Int, specificity: Int)?

        for (index, hotkey) in hotkeys.enumerated() {
            guard let hotkey, hotkey.matches(trigger: trigger, modifiers: modifiers) else { continue }
            let specificity = hotkey.modifiers.rawValue.nonzeroBitCount
            if best == nil || specificity > best!.specificity {
                best = (index, specificity)
            }
        }
        return best?.index
    }
}

/// Names for the keys people actually bind, in both directions.
public enum KeyCodes {
    public static let table: [(name: String, code: UInt16)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5),
        ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45),
        ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32),
        ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
        ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29),
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97),
        ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111),
        ("F13", 105), ("F14", 107), ("F15", 113), ("F16", 106), ("F17", 64), ("F18", 79),
        ("Space", 49), ("Tab", 48), ("`", 50), ("Caps Lock", 57),
        ("Keypad 0", 82), ("Keypad 1", 83), ("Keypad 2", 84), ("Keypad 3", 85),
        ("Keypad 4", 86), ("Keypad 5", 87), ("Keypad 6", 88), ("Keypad 7", 89),
        ("Keypad 8", 91), ("Keypad 9", 92),
    ]

    public static func name(for code: UInt16) -> String? {
        table.first { $0.code == code }?.name
    }

    public static func code(for name: String) -> UInt16? {
        table.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.code
    }
}
