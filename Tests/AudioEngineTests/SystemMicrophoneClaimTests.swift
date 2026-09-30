import CoreAudio
import Testing
@testable import AudioEngine

@Suite("SystemMicrophoneClaim")
struct SystemMicrophoneClaimTests {

    let builtIn = AudioDevice(id: 1, uid: "BuiltIn", name: "MacBook Pro Microphone",
                              inputChannels: 1, outputChannels: 0,
                              transportType: kAudioDeviceTransportTypeBuiltIn)
    let virtual = AudioDevice(id: 2, uid: "Virtual", name: "BlackHole 2ch",
                              inputChannels: 2, outputChannels: 2,
                              transportType: kAudioDeviceTransportTypeVirtual)
    let headset = AudioDevice(id: 3, uid: "Headset", name: "Zone Vibe Wireless",
                              inputChannels: 1, outputChannels: 0,
                              transportType: kAudioDeviceTransportTypeBluetooth)
    let iPhone = AudioDevice(id: 4, uid: "iPhone", name: "iPhone Microphone",
                             inputChannels: 1, outputChannels: 0,
                             transportType: kAudioDeviceTransportTypeContinuityCaptureWireless)

    var devices: [AudioDevice] { [builtIn, virtual, headset, iPhone] }

    @Test("gives the default input back to the device it displaced")
    func restoresDisplacedDevice() {
        let target = SystemMicrophoneClaim.restoreTarget(
            remembered: "Headset", virtual: virtual, devices: devices)
        #expect(target == headset)
    }

    @Test("still hands back a real microphone when nothing was remembered")
    func restoresWithoutMemory() {
        // The state a crash leaves behind. Without a fallback the virtual
        // device stays the system microphone and every other app — Zoom,
        // FaceTime — records silence, for good.
        let target = SystemMicrophoneClaim.restoreTarget(
            remembered: nil, virtual: virtual, devices: devices)
        #expect(target == builtIn)
    }

    @Test("falls back when the remembered device has been unplugged")
    func restoresWhenRememberedIsGone() {
        let target = SystemMicrophoneClaim.restoreTarget(
            remembered: "Unplugged", virtual: virtual, devices: devices)
        #expect(target == builtIn)
    }

    @Test("never hands the default input to the iPhone by itself")
    func neverFallsBackToPhone() {
        let target = SystemMicrophoneClaim.restoreTarget(
            remembered: nil, virtual: virtual, devices: [virtual, iPhone])
        #expect(target == nil)
    }

    @Test("gives the iPhone back if that is genuinely what it displaced")
    func restoresRememberedPhone() {
        // Handing back what the user had is not the app choosing the phone.
        let target = SystemMicrophoneClaim.restoreTarget(
            remembered: "iPhone", virtual: virtual, devices: devices)
        #expect(target == iPhone)
    }

    @Test("never hands the default input back to the virtual device")
    func neverRestoresVirtual() {
        let target = SystemMicrophoneClaim.restoreTarget(
            remembered: "Virtual", virtual: virtual, devices: devices)
        #expect(target != virtual)
    }

    @Test("never hands the default input back to another loopback device")
    func skipsOtherLoopback() {
        // Switching from BlackHole to our driver records BlackHole as the
        // displaced input; restoring it would leave every app recording silence.
        let ours = AudioDevice(id: 9, uid: "iSoundboard_UID", name: "iSoundboard",
                               inputChannels: 2, outputChannels: 2)
        let blackHole = AudioDevice(id: 8, uid: "BlackHole2ch_UID", name: "BlackHole 2ch",
                                    inputChannels: 2, outputChannels: 2)
        let target = SystemMicrophoneClaim.restoreTarget(
            remembered: "BlackHole2ch_UID", virtual: ours, devices: [blackHole, builtIn, ours])
        #expect(target == builtIn)
    }

    @Test("switching from BlackHole to our driver keeps the real microphone remembered")
    func keepsRealMicAcrossLoopbackSwitch() {
        let ours = AudioDevice(id: 9, uid: "iSoundboard_UID", name: "iSoundboard",
                               inputChannels: 2, outputChannels: 2)
        let blackHole = AudioDevice(id: 8, uid: "BlackHole2ch_UID", name: "BlackHole 2ch",
                                    inputChannels: 2, outputChannels: 2)
        #expect(SystemMicrophoneClaim.remembered(current: blackHole, virtual: ours, previous: "USBMic") == "USBMic")
        #expect(SystemMicrophoneClaim.remembered(current: headset, virtual: ours, previous: "USBMic") == "Headset")
        #expect(SystemMicrophoneClaim.remembered(current: ours, virtual: ours, previous: "USBMic") == "USBMic")
        #expect(SystemMicrophoneClaim.remembered(current: nil, virtual: ours, previous: "USBMic") == "USBMic")
    }
}
