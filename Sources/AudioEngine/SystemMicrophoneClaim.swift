import CoreAudio
import Foundation

/// Makes the virtual device the system default input, so a game picks it up
/// without the player configuring anything.
///
/// This changes a system-wide setting, so it must be given back. If the app
/// exits leaving the virtual microphone as the default input, every other app —
/// Zoom, FaceTime, voice memos — records silence, because nothing is feeding it.
/// The previous device is therefore remembered and restored on release, and the
/// remembered UID is handed out so it can survive a crash and be restored on the
/// next launch.
public final class SystemMicrophoneClaim {

    /// The device that was the system default before we took over.
    public private(set) var previousDeviceUID: String?
    public private(set) var isClaimed = false

    public init(previousDeviceUID: String? = nil) {
        self.previousDeviceUID = previousDeviceUID
    }

    /// Point the system default input at the virtual device.
    @discardableResult
    public func claim(_ virtual: AudioDevice) -> Bool {
        let current = AudioDeviceRegistry.defaultInputDevice()

        // Already ours: keep whatever real device we remembered first, or we
        // would "restore" to the virtual device later.
        if current?.uid == virtual.uid {
            isClaimed = true
            return true
        }

        previousDeviceUID = Self.remembered(current: current, virtual: virtual, previous: previousDeviceUID)

        guard AudioDeviceRegistry.setDefaultInputDevice(virtual.id) else { return false }
        isClaimed = true
        return true
    }

    /// What to remember as the device to hand back. Another loopback device
    /// holding the default (switching from BlackHole to our driver) is not the
    /// user's microphone, so the one remembered before it is kept.
    static func remembered(current: AudioDevice?, virtual: AudioDevice, previous: String?) -> String? {
        guard let current, current.uid != virtual.uid, !current.isLoopback else { return previous }
        return current.uid
    }

    /// Which device the system default input should be handed back to.
    ///
    /// Normally the one we displaced. But the remembered device can be missing
    /// — unplugged since, or never recorded because a crash skipped the
    /// bookkeeping — and "nothing to restore" is not an acceptable answer:
    /// leaving the virtual device as the system microphone makes every other
    /// app record silence, permanently, because the next launch inherits the
    /// same state and has nothing to remember either.
    ///
    /// So it falls back to a device the app is allowed to choose on its own,
    /// which deliberately excludes the user's iPhone.
    static func restoreTarget(remembered: String?,
                              virtual: AudioDevice?,
                              devices: [AudioDevice]) -> AudioDevice? {
        if let remembered,
           let device = devices.first(where: {
               $0.uid == remembered && $0.canRecord && $0.uid != virtual?.uid && !$0.isLoopback
           }) {
            return device
        }
        return DeviceSelection.autoSelectableInputs(virtual: virtual, from: devices).first
    }

    /// Give the system default input back to whatever had it.
    @discardableResult
    public func release(from devices: [AudioDevice], virtual: AudioDevice?) -> Bool {
        defer {
            isClaimed = false
            previousDeviceUID = nil
        }
        guard let device = Self.restoreTarget(remembered: previousDeviceUID,
                                              virtual: virtual,
                                              devices: devices) else { return false }
        return AudioDeviceRegistry.setDefaultInputDevice(device.id)
    }

    /// Recover from a previous run that did not get to release — the app was
    /// force-quit, or crashed, or released with nothing remembered.
    ///
    /// `previousUID` is optional because the run that crashed may never have
    /// recorded one. The virtual device still has to be handed back either way.
    @discardableResult
    public static func restoreAfterCrash(previousUID: String?,
                                         virtual: AudioDevice?,
                                         devices: [AudioDevice]) -> Bool {
        guard let current = AudioDeviceRegistry.defaultInputDevice(),
              let virtual, current.uid == virtual.uid,
              let device = restoreTarget(remembered: previousUID,
                                         virtual: virtual, devices: devices)
        else { return false }
        return AudioDeviceRegistry.setDefaultInputDevice(device.id)
    }
}
