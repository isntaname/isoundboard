import Testing
@testable import InputControl

@Suite("Hotkey")
struct HotkeyTests {

    @Test("matches the same key with the same modifiers")
    func matchesExactly() {
        let hotkey = Hotkey(keyCode: 9, modifiers: [.command, .shift])
        #expect(hotkey.matches(keyCode: 9, modifiers: [.command, .shift]))
    }

    @Test("ignores modifiers the user isn't holding but didn't bind")
    func rejectsMissingModifiers() {
        let hotkey = Hotkey(keyCode: 9, modifiers: [.command])
        #expect(!hotkey.matches(keyCode: 9, modifiers: []))
    }

    @Test("a bare key still fires while an unrelated modifier is held")
    func bareKeyToleratesExtraModifiers() {
        // In-game PTT bound to a bare key still triggers while crouching with
        // shift held. A strict equality check would drop the sound mid-fight.
        let hotkey = Hotkey(keyCode: 9, modifiers: [])
        #expect(hotkey.matches(keyCode: 9, modifiers: [.shift]))
    }

    @Test("a modified hotkey does not fire on the bare key")
    func modifiedHotkeyNeedsItsModifiers() {
        let hotkey = Hotkey(keyCode: 9, modifiers: [.control, .option])
        #expect(!hotkey.matches(keyCode: 9, modifiers: [.control]))
    }

    @Test("has a readable description for the UI")
    func describesItself() {
        #expect(Hotkey(keyCode: 9, modifiers: [.command]).displayName == "⌘V")
        #expect(Hotkey(keyCode: 9, modifiers: []).displayName == "V")
    }
}
