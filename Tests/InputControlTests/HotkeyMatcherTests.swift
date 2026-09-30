import Testing
@testable import InputControl

@Suite("HotkeyMatcher")
struct HotkeyMatcherTests {

    let v: UInt16 = 9

    @Test("finds the only matching hotkey")
    func findsSingleMatch() {
        let hotkeys: [Hotkey?] = [Hotkey(keyCode: v)]
        #expect(HotkeyMatcher.bestMatch(hotkeys, keyCode: v, modifiers: []) == 0)
    }

    @Test("ignores sounds with no hotkey assigned")
    func skipsUnassigned() {
        let hotkeys: [Hotkey?] = [nil, Hotkey(keyCode: v)]
        #expect(HotkeyMatcher.bestMatch(hotkeys, keyCode: v, modifiers: []) == 1)
    }

    @Test("the most specific hotkey wins")
    func mostSpecificWins() {
        // A bare key also matches when extra modifiers are held, so plain V and
        // Shift-V both match a Shift-V press. The one that asked for Shift is
        // clearly the intended target — otherwise list order decides, and the
        // wrong clip fires.
        let hotkeys: [Hotkey?] = [
            Hotkey(keyCode: v),
            Hotkey(keyCode: v, modifiers: [.shift]),
        ]
        #expect(HotkeyMatcher.bestMatch(hotkeys, keyCode: v, modifiers: [.shift]) == 1)
    }

    @Test("order in the list does not decide the winner")
    func orderIndependent() {
        let hotkeys: [Hotkey?] = [
            Hotkey(keyCode: v, modifiers: [.shift]),
            Hotkey(keyCode: v),
        ]
        #expect(HotkeyMatcher.bestMatch(hotkeys, keyCode: v, modifiers: [.shift]) == 0)
    }

    @Test("a bare press does not fire a modified hotkey")
    func barePressSkipsModified() {
        let hotkeys: [Hotkey?] = [Hotkey(keyCode: v, modifiers: [.shift])]
        #expect(HotkeyMatcher.bestMatch(hotkeys, keyCode: v, modifiers: []) == nil)
    }

    @Test("returns nil when nothing matches")
    func noMatch() {
        let hotkeys: [Hotkey?] = [Hotkey(keyCode: v)]
        #expect(HotkeyMatcher.bestMatch(hotkeys, keyCode: 11, modifiers: []) == nil)
    }
}

@Suite("HotkeyRouting")
struct HotkeyRoutingTests {

    let sounds: [Hotkey?] = [
        Hotkey(keyCode: 9),                              // V
        Hotkey(keyCode: 9, modifiers: [.shift]),         // ⇧V
        nil,                                             // no hotkey set
    ]

    @Test("a plain key plays its clip")
    func playsClip() {
        let action = HotkeyMatcher.action(soundHotkeys: sounds, stopHotkey: Hotkey(keyCode: 53),
                                          trigger: .key(9), modifiers: [])
        #expect(action == .play(0))
    }

    @Test("the stop key stops everything")
    func stops() {
        let action = HotkeyMatcher.action(soundHotkeys: sounds, stopHotkey: Hotkey(keyCode: 53),
                                          trigger: .key(53), modifiers: [])
        #expect(action == .stopAll)
    }

    @Test("an unbound key does nothing")
    func ignoresUnbound() {
        let action = HotkeyMatcher.action(soundHotkeys: sounds, stopHotkey: Hotkey(keyCode: 53),
                                          trigger: .key(40), modifiers: [])
        #expect(action == nil)
    }

    @Test("works with no stop key set")
    func noStopKey() {
        let action = HotkeyMatcher.action(soundHotkeys: sounds, stopHotkey: nil,
                                          trigger: .key(9), modifiers: [])
        #expect(action == .play(0))
    }

    @Test("the most specific binding still wins across both kinds")
    func specificityAcrossKinds() {
        // ⇧V is bound to a clip and plain V to stop. Holding shift must play
        // the clip, not stop — otherwise stop swallows every shifted variant.
        let action = HotkeyMatcher.action(soundHotkeys: sounds, stopHotkey: Hotkey(keyCode: 9),
                                          trigger: .key(9), modifiers: [.shift])
        #expect(action == .play(1))
    }

    @Test("a clip wins when it is bound to the same key as stop")
    func clipWinsTie() {
        // Both bound to plain V — a mistake the UI allows. Resolve it the same
        // way every time rather than by list order luck.
        let action = HotkeyMatcher.action(soundHotkeys: sounds, stopHotkey: Hotkey(keyCode: 9),
                                          trigger: .key(9), modifiers: [])
        #expect(action == .play(0))
    }

    @Test("a mouse button can stop playback")
    func mouseStop() {
        let action = HotkeyMatcher.action(soundHotkeys: sounds,
                                          stopHotkey: Hotkey(trigger: .mouseButton(3)),
                                          trigger: .mouseButton(3), modifiers: [])
        #expect(action == .stopAll)
    }
}
