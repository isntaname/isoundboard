import Testing
import Foundation
@testable import InputControl

@Suite("Trigger")
struct TriggerTests {

    @Test("a mouse hotkey matches that mouse button")
    func matchesMouseButton() {
        let hotkey = Hotkey(trigger: .mouseButton(3))
        #expect(hotkey.matches(trigger: .mouseButton(3), modifiers: []))
    }

    @Test("a mouse hotkey does not match a different button")
    func rejectsOtherButton() {
        let hotkey = Hotkey(trigger: .mouseButton(3))
        #expect(!hotkey.matches(trigger: .mouseButton(4), modifiers: []))
    }

    @Test("a mouse hotkey does not match a key with the same number")
    func mouseAndKeyDoNotCollide() {
        // Button 4 and key code 4 are unrelated; conflating them would fire the
        // wrong clip.
        let hotkey = Hotkey(trigger: .mouseButton(4))
        #expect(!hotkey.matches(trigger: .key(4), modifiers: []))
    }

    @Test("names mouse buttons readably")
    func namesMouseButtons() {
        #expect(Hotkey(trigger: .mouseButton(2)).displayName == "Middle Click")
        #expect(Hotkey(trigger: .mouseButton(3)).displayName == "Mouse 4")
        #expect(Hotkey(trigger: .mouseButton(4)).displayName == "Mouse 5")
        #expect(Hotkey(trigger: .key(9), modifiers: [.shift]).displayName == "⇧V")
    }

    @Test("reads hotkeys saved before mouse buttons existed")
    func migratesOldFormat() throws {
        // The saved library uses {"keyCode": …}. Dropping it would silently
        // clear every hotkey the user has already set.
        let old = #"{"keyCode":40,"modifiers":4}"#.data(using: .utf8)!
        let hotkey = try JSONDecoder().decode(Hotkey.self, from: old)
        #expect(hotkey.trigger == .key(40))
        #expect(hotkey.modifiers == .option)
    }

    @Test("round-trips a mouse binding")
    func roundTripsMouse() throws {
        let hotkey = Hotkey(trigger: .mouseButton(3), modifiers: [.control])
        let data = try JSONEncoder().encode(hotkey)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == hotkey)
    }
}
