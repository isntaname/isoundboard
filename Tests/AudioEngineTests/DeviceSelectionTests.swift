import Testing
@testable import AudioEngine

@Suite("DeviceSelection")
struct DeviceSelectionTests {

    let devices = [
        AudioDevice(id: 1, uid: "BuiltInMic", name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0),
        AudioDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2),
        AudioDevice(id: 3, uid: "AirPods", name: "AirPods Pro", inputChannels: 1, outputChannels: 2),
    ]

    @Test("prefers an exact UID match")
    func matchesByUID() {
        let picked = DeviceSelection.resolve(uid: "BlackHole2ch_UID", name: nil, from: devices)
        #expect(picked?.name == "BlackHole 2ch")
    }

    @Test("falls back to the remembered name when the UID is gone")
    func fallsBackToName() {
        // UIDs change when a device is reinstalled; the name usually survives.
        let picked = DeviceSelection.resolve(uid: "StaleUID", name: "BlackHole 2ch", from: devices)
        #expect(picked?.uid == "BlackHole2ch_UID")
    }

    @Test("returns nil rather than guessing when nothing matches")
    func noGuessing() {
        // Silently picking the wrong mic is worse than reporting none.
        let picked = DeviceSelection.resolve(uid: "Gone", name: "Also Gone", from: devices)
        #expect(picked == nil)
    }

    @Test("prefers our driver over BlackHole")
    func prefersOurDriver() {
        let ours = AudioDevice(id: 9, uid: "iSoundboard_UID", name: "iSoundboard", inputChannels: 2, outputChannels: 2)
        #expect(DeviceSelection.preferredVirtual(from: devices + [ours])?.uid == "iSoundboard_UID")
    }

    @Test("uses BlackHole when our driver is absent")
    func fallsBackToBlackHole() {
        #expect(DeviceSelection.preferredVirtual(from: devices)?.uid == "BlackHole2ch_UID")
    }

    @Test("never guesses: a headset that plays and records is not a virtual mic")
    func noGuessingVirtual() {
        let headset = AudioDevice(id: 5, uid: "USBHeadset", name: "USB Headset", inputChannels: 1, outputChannels: 2)
        #expect(DeviceSelection.preferredVirtual(from: [headset]) == nil)
    }
}
