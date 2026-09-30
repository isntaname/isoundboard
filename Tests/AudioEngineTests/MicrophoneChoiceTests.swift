import CoreAudio
import Testing
@testable import AudioEngine

@Suite("MicrophoneChoice")
struct MicrophoneChoiceTests {

    let builtIn = AudioDevice(id: 1, uid: "BuiltIn", name: "MacBook Pro Microphone",
                              inputChannels: 1, outputChannels: 0,
                              transportType: kAudioDeviceTransportTypeBuiltIn)
    let virtual = AudioDevice(id: 2, uid: "Virtual", name: "BlackHole 2ch",
                              inputChannels: 2, outputChannels: 2,
                              transportType: kAudioDeviceTransportTypeVirtual)
    let headset = AudioDevice(id: 3, uid: "Headset", name: "Zone Vibe Wireless",
                              inputChannels: 1, outputChannels: 0,
                              transportType: kAudioDeviceTransportTypeBluetooth)
    /// An iPhone offering itself over Continuity Capture. Merely opening it
    /// wakes the phone and takes it over, so it must never be chosen for the
    /// user — only by the user.
    let iPhone = AudioDevice(id: 4, uid: "iPhone", name: "iPhone Microphone",
                             inputChannels: 1, outputChannels: 0,
                             transportType: kAudioDeviceTransportTypeContinuityCaptureWireless)

    var devices: [AudioDevice] { [builtIn, virtual, headset] }

    /// CoreAudio hands devices back in its own order, and the iPhone can come
    /// first — so it is first here too.
    var devicesWithPhone: [AudioDevice] { [iPhone, virtual, headset, builtIn] }

    @Test("uses the device the user picked")
    func honoursExplicitChoice() {
        let picked = DeviceSelection.microphone(preferredUID: "Headset", systemDefault: builtIn,
                                                virtual: virtual, from: devices)
        #expect(picked == headset)
    }

    @Test("never returns the virtual device, even if explicitly chosen")
    func refusesVirtualWhenChosen() {
        // Capturing the device we write into is a feedback loop.
        let picked = DeviceSelection.microphone(preferredUID: "Virtual", systemDefault: builtIn,
                                                virtual: virtual, from: devices)
        #expect(picked != virtual)
    }

    @Test("never returns the virtual device when it has become the system default")
    func refusesVirtualAsSystemDefault() {
        // This is the situation the app creates by claiming the default input:
        // following the system default would capture our own output.
        let picked = DeviceSelection.microphone(preferredUID: nil, systemDefault: virtual,
                                                virtual: virtual, from: devices)
        #expect(picked != virtual)
        #expect(picked != nil)
    }

    @Test("follows the system default when it is a real device")
    func followsSystemDefault() {
        let picked = DeviceSelection.microphone(preferredUID: nil, systemDefault: headset,
                                                virtual: virtual, from: devices)
        #expect(picked == headset)
    }

    @Test("falls back to a real input when nothing else is usable")
    func fallsBackToRealInput() {
        let picked = DeviceSelection.microphone(preferredUID: "Gone", systemDefault: virtual,
                                                virtual: virtual, from: devices)
        #expect(picked?.canRecord == true)
        #expect(picked != virtual)
    }

    @Test("returns nil when the only input is the virtual device")
    func nilWhenNoRealInput() {
        let picked = DeviceSelection.microphone(preferredUID: nil, systemDefault: virtual,
                                                virtual: virtual, from: [virtual])
        #expect(picked == nil)
    }

    // MARK: - What "System Default" means once we have taken the default input

    @Test("the effective default is the real one when we have not claimed it")
    func effectiveDefaultPassesThrough() {
        let effective = DeviceSelection.effectiveSystemDefaultInput(
            current: headset, virtual: virtual, remembered: nil, from: devices)
        #expect(effective == headset)
    }

    @Test("the effective default is the device we displaced, not our own")
    func effectiveDefaultUsesRemembered() {
        // The app made the virtual device the system default. "System Default"
        // must still mean the user's real microphone — the one we displaced —
        // not the virtual device and not an arbitrary other input.
        let effective = DeviceSelection.effectiveSystemDefaultInput(
            current: virtual, virtual: virtual, remembered: "Headset", from: devices)
        #expect(effective == headset)
    }

    @Test("falls back to a real input when the displaced device is gone")
    func effectiveDefaultFallsBack() {
        let effective = DeviceSelection.effectiveSystemDefaultInput(
            current: virtual, virtual: virtual, remembered: "Unplugged", from: devices)
        #expect(effective?.canRecord == true)
        #expect(effective != virtual)
    }

    @Test("following System Default picks the displaced device")
    func microphoneFollowsDisplacedDefault() {
        let effective = DeviceSelection.effectiveSystemDefaultInput(
            current: virtual, virtual: virtual, remembered: "Headset", from: devices)
        let picked = DeviceSelection.microphone(preferredUID: nil, systemDefault: effective,
                                                virtual: virtual, from: devices)
        #expect(picked == headset)
    }

    // MARK: - Continuity Capture (the user's iPhone)

    @Test("never picks up the iPhone on its own")
    func neverAutoSelectsContinuityDevice() {
        // The app claimed the default input, so there is nothing to follow and
        // the fallback decides. It must not reach for the phone.
        let picked = DeviceSelection.microphone(preferredUID: nil, systemDefault: nil,
                                                virtual: virtual, from: devicesWithPhone)
        #expect(picked == builtIn)
    }

    @Test("ignores the iPhone even when macOS made it the system default")
    func ignoresContinuityAsSystemDefault() {
        let picked = DeviceSelection.microphone(preferredUID: nil, systemDefault: iPhone,
                                                virtual: virtual, from: devicesWithPhone)
        #expect(picked == builtIn)
    }

    @Test("uses the iPhone when the user asks for it by name")
    func honoursExplicitContinuityChoice() {
        let picked = DeviceSelection.microphone(preferredUID: "iPhone", systemDefault: builtIn,
                                                virtual: virtual, from: devicesWithPhone)
        #expect(picked == iPhone)
    }

    @Test("stays silent rather than waking the iPhone as a last resort")
    func refusesContinuityAsLastResort() {
        // Nothing else can record. Waking the user's phone uninvited is worse
        // than reporting that there is no microphone.
        let picked = DeviceSelection.microphone(preferredUID: nil, systemDefault: nil,
                                                virtual: virtual, from: [iPhone, virtual])
        #expect(picked == nil)
    }

    @Test("prefers the built-in microphone when falling back")
    func fallbackPrefersBuiltIn() {
        // Whatever CoreAudio happens to list first, the Mac's own microphone is
        // the safe default — it is always there and never costs anything to open.
        let picked = DeviceSelection.microphone(preferredUID: nil, systemDefault: nil,
                                                virtual: virtual, from: [headset, virtual, builtIn])
        #expect(picked == builtIn)
    }

    @Test("never reports the iPhone as the effective System Default")
    func effectiveDefaultSkipsContinuity() {
        let effective = DeviceSelection.effectiveSystemDefaultInput(
            current: iPhone, virtual: virtual, remembered: nil, from: devicesWithPhone)
        #expect(effective == builtIn)
    }

    @Test("does not restore to the iPhone when the displaced device was one")
    func effectiveDefaultSkipsRememberedContinuity() {
        let effective = DeviceSelection.effectiveSystemDefaultInput(
            current: virtual, virtual: virtual, remembered: "iPhone", from: devicesWithPhone)
        #expect(effective == builtIn)
    }

    @Test("never takes another loopback device as the microphone")
    func skipsOtherLoopback() {
        let ours = AudioDevice(id: 9, uid: "iSoundboard_UID", name: "iSoundboard",
                               inputChannels: 2, outputChannels: 2)
        let blackHole = AudioDevice(id: 8, uid: "BlackHole2ch_UID", name: "BlackHole 2ch",
                                    inputChannels: 2, outputChannels: 2)
        let all = [blackHole, builtIn, ours]
        // BlackHole was the system default because the app had claimed it.
        let effective = DeviceSelection.effectiveSystemDefaultInput(
            current: blackHole, virtual: ours, remembered: "BlackHole2ch_UID", from: all)
        #expect(effective == builtIn)
        #expect(DeviceSelection.microphone(preferredUID: nil, systemDefault: blackHole,
                                           virtual: ours, from: all) == builtIn)
        #expect(DeviceSelection.autoSelectableInputs(virtual: ours, from: [blackHole]).isEmpty)
    }
}

@Suite("ContinuityTransportTypes")
struct ContinuityTransportTypeTests {

    private func device(_ transport: UInt32) -> AudioDevice {
        AudioDevice(id: 1, uid: "u", name: "n", inputChannels: 1, outputChannels: 0,
                    transportType: transport)
    }

    @Test("recognises every spelling macOS uses for Continuity Capture")
    func recognisesAllContinuitySpellings() {
        #expect(device(kAudioDeviceTransportTypeContinuityCaptureWired).isContinuityCapture)
        #expect(device(kAudioDeviceTransportTypeContinuityCaptureWireless).isContinuityCapture)
        // The macOS 13.0 spelling, deprecated but still reported by some systems.
        #expect(device(0x6363_6170).isContinuityCapture)
    }

    @Test("does not mistake ordinary microphones for a phone")
    func leavesRealDevicesAlone() {
        for transport in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                          kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeVirtual,
                          kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeUnknown] {
            #expect(!device(transport).isContinuityCapture)
        }
    }
}
