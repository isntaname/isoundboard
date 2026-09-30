import Testing
@testable import SoundboardCore

@Suite("MicrophoneMode")
struct MicrophoneModeTests {

    @Test("muted never passes the microphone through")
    func mutedIsAlwaysSilent() {
        #expect(MicrophoneMode.muted.micGain(isClipPlaying: false) == 0)
        #expect(MicrophoneMode.muted.micGain(isClipPlaying: true) == 0)
    }

    @Test("always keeps the microphone open, clip or no clip")
    func alwaysStaysOpen() {
        #expect(MicrophoneMode.always.micGain(isClipPlaying: false) == 1)
        #expect(MicrophoneMode.always.micGain(isClipPlaying: true) == 1)
    }

    @Test("whenIdle drops the microphone while a clip plays")
    func whenIdleDucksDuringPlayback() {
        // Keeps the clip clean: no room noise or breathing under it.
        #expect(MicrophoneMode.whenIdle.micGain(isClipPlaying: false) == 1)
        #expect(MicrophoneMode.whenIdle.micGain(isClipPlaying: true) == 0)
    }
}
