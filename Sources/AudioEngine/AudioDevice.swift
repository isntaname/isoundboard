import CoreAudio

/// A CoreAudio device, flattened to the parts we care about.
public struct AudioDevice: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    /// How the device is attached — built-in, USB, Bluetooth, Continuity, …
    /// Zero means "not asked", which is how most test fixtures describe it.
    public let transportType: UInt32

    public init(id: AudioDeviceID, uid: String, name: String,
                inputChannels: Int, outputChannels: Int, transportType: UInt32 = 0) {
        self.id = id
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.transportType = transportType
    }

    public var canRecord: Bool { inputChannels > 0 }
    public var canPlay: Bool { outputChannels > 0 }

    /// An iPhone or iPad offering itself as a microphone over Continuity.
    ///
    /// These sit in the device list whenever the phone is nearby, but they are
    /// not free to open: starting a stream on one wakes the phone, puts it into
    /// Continuity mode and hands it the audio. That is a thing to do because
    /// the user asked, never because an app launched.
    public var isContinuityCapture: Bool {
        // 'ccap' is the deprecated macOS 13.0 spelling, still what some systems
        // report; matched by value so the deprecation warning stays out.
        let continuity: Set<UInt32> = [
            kAudioDeviceTransportTypeContinuityCaptureWired,
            kAudioDeviceTransportTypeContinuityCaptureWireless,
            0x63636170,  // 'ccap'
        ]
        return continuity.contains(transportType)
    }

    /// A virtual loopback device the app can write into: ours or BlackHole.
    /// Never a microphone, whichever of them is currently in use — after a
    /// switch, the other one is still the system default input for a moment.
    public var isLoopback: Bool {
        uid == DriverInstaller.deviceUID || uid == DriverInstaller.blackHoleUID
    }

    /// The Mac's own microphone. Always present, and costs nothing to open.
    public var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
}

public enum DeviceSelection {
    /// Resolve a remembered device. UIDs are stable but change when a driver
    /// is reinstalled, so the name is kept as a fallback.
    ///
    /// Returns nil rather than guessing — silently routing to the wrong
    /// microphone is worse than reporting that the device is missing.
    public static func resolve(uid: String?, name: String?, from devices: [AudioDevice]) -> AudioDevice? {
        if let uid, let match = devices.first(where: { $0.uid == uid }) { return match }
        if let name, let match = devices.first(where: { $0.name == name }) { return match }
        return nil
    }

    /// The device the game should record from: our driver, else a BlackHole
    /// the user installed. Never any other device that merely plays and
    /// records; a USB headset would pass that test.
    public static func preferredVirtual(from devices: [AudioDevice]) -> AudioDevice? {
        for uid in [DriverInstaller.deviceUID, DriverInstaller.blackHoleUID] {
            if let match = devices.first(where: { $0.uid == uid }) { return match }
        }
        return nil
    }

    /// Choose the real microphone, never the virtual device.
    ///
    /// The app makes the virtual device the system default input so games pick
    /// it up without configuration. That makes "follow the system default" a
    /// trap: it would capture the device we write into, feeding our own output
    /// back into itself. The virtual device is therefore excluded outright,
    /// whatever route selected it.
    public static func microphone(preferredUID: String?,
                                  systemDefault: AudioDevice?,
                                  virtual: AudioDevice?,
                                  from devices: [AudioDevice]) -> AudioDevice? {
        func usable(_ device: AudioDevice?) -> AudioDevice? {
            guard let device, device.canRecord else { return nil }
            if let virtual, device.uid == virtual.uid { return nil }
            return device
        }

        // An explicit choice is honoured whatever it is — including the phone.
        if let preferredUID, let match = usable(devices.first { $0.uid == preferredUID }) {
            return match
        }
        if let match = usable(systemDefault), !match.isContinuityCapture, !match.isLoopback { return match }

        // Nothing was chosen, so this is the app deciding for itself. It may
        // only reach for a device that is free to open — never the phone.
        return autoSelectableInputs(virtual: virtual, from: devices).first
    }

    /// The inputs the app may switch to on its own, best first.
    ///
    /// The Mac's own microphone leads: it is always there, and opening it has
    /// no effect on anything outside the Mac. Continuity Capture devices — the
    /// user's iPhone or iPad — are excluded outright, because choosing one
    /// takes over the phone. If that is what the user wants, they can pick it
    /// by name and the choice above honours it.
    public static func autoSelectableInputs(virtual: AudioDevice?,
                                            from devices: [AudioDevice]) -> [AudioDevice] {
        let usable = devices.filter {
            $0.canRecord && $0.uid != virtual?.uid && !$0.isContinuityCapture && !$0.isLoopback
        }
        return usable.filter(\.isBuiltIn) + usable.filter { !$0.isBuiltIn }
    }

    /// What "System Default" should mean for the app's own microphone.
    ///
    /// Once the app makes the virtual device the system default input, the real
    /// default is gone — so following it literally would either capture our own
    /// output or land on an arbitrary device. The device we displaced is the one
    /// the user actually meant, so that is what "System Default" resolves to.
    public static func effectiveSystemDefaultInput(current: AudioDevice?,
                                                   virtual: AudioDevice?,
                                                   remembered: String?,
                                                   from devices: [AudioDevice]) -> AudioDevice? {
        if let current, current.uid != virtual?.uid, current.canRecord,
           !current.isContinuityCapture, !current.isLoopback { return current }

        if let remembered,
           let displaced = devices.first(where: { $0.uid == remembered && $0.canRecord }),
           !displaced.isContinuityCapture, !displaced.isLoopback {
            return displaced
        }
        return autoSelectableInputs(virtual: virtual, from: devices).first
    }
}
