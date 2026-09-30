import Testing
@testable import SoundboardCore

@Suite("SetupStatus")
struct SetupStatusTests {

    func status(virtualDevice: Bool = true,
                audioRunning: Bool = true,
                hotkeys: Bool = true,
                microphone: Bool = true,
                mode: MicrophoneMode = .always) -> SetupStatus {
        SetupStatus.evaluate(hasVirtualDevice: virtualDevice,
                             audioRunning: audioRunning,
                             hotkeysWorking: hotkeys,
                             microphoneGranted: microphone,
                             micMode: mode)
    }

    @Test("everything configured is ready")
    func readyWhenComplete() {
        #expect(status().isReady)
    }

    @Test("no virtual device blocks the soundboard")
    func needsVirtualDevice() {
        let result = status(virtualDevice: false)
        #expect(!result.isReady)
        #expect(result.unmet.contains(.virtualDevice))
    }

    @Test("audio not running blocks the soundboard")
    func needsAudioRunning() {
        #expect(status(audioRunning: false).unmet.contains(.audioRunning))
    }

    @Test("hotkeys are required — a soundboard you must click is not one")
    func needsHotkeys() {
        #expect(status(hotkeys: false).unmet.contains(.inputMonitoring))
    }

    @Test("microphone access is required when the mic is mixed in")
    func needsMicrophoneWhenMixing() {
        #expect(status(microphone: false, mode: .always).unmet.contains(.microphone))
        #expect(status(microphone: false, mode: .whenIdle).unmet.contains(.microphone))
    }

    @Test("microphone access is not required when the mic is muted")
    func microphoneOptionalWhenMuted() {
        // Muted means the mic is never mixed in, so refusing access is a valid
        // configuration, not an incomplete one.
        let result = status(microphone: false, mode: .muted)
        #expect(!result.unmet.contains(.microphone))
        #expect(result.isReady)
    }

    @Test("lists the most fundamental problem first")
    func ordersByImportance() {
        // Fixing audio routing before chasing permissions.
        let result = status(virtualDevice: false, audioRunning: false, hotkeys: false)
        #expect(result.unmet.first == .virtualDevice)
    }
}
