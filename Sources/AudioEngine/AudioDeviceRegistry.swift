import CoreAudio
import Foundation

public enum AudioDeviceError: Error, CustomStringConvertible {
    case propertyFailed(String, OSStatus)

    public var description: String {
        switch self {
        case let .propertyFailed(what, status):
            return "CoreAudio \(what) failed (OSStatus \(status))"
        }
    }
}

/// Enumerates CoreAudio devices via the HAL.
public enum AudioDeviceRegistry {

    public static func allDevices() throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw AudioDeviceError.propertyFailed("device list size", status) }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        guard status == noErr else { throw AudioDeviceError.propertyFailed("device list", status) }

        return ids.compactMap(describe)
    }

    public static func defaultInputDevice() -> AudioDevice? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    public static func defaultOutputDevice() -> AudioDevice? {
        defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr else { return nil }
        return describe(id)
    }

    @discardableResult
    public static func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        return status == noErr
    }

    // MARK: - Sample rate

    public static func nominalSampleRate(of id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    public static func supportedSampleRates(of id: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        // Discrete rates report minimum == maximum.
        return ranges.map(\.mMaximum)
    }

    /// Pin a device to a sample rate.
    ///
    /// Needed because a Bluetooth headset negotiating HFP at 16 kHz can drag the
    /// virtual device down with it, leaving the mixer and the virtual device on
    /// different rates and the output silent.
    @discardableResult
    public static func setNominalSampleRate(_ rate: Double, on id: AudioDeviceID) -> Bool {
        if let current = nominalSampleRate(of: id), abs(current - rate) < 1 { return true }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = rate
        let status = AudioObjectSetPropertyData(id, &address, 0, nil,
                                                UInt32(MemoryLayout<Double>.size), &value)
        guard status == noErr else { return false }

        // The change is asynchronous; wait briefly for it to take effect.
        for _ in 0..<40 {
            if let current = nominalSampleRate(of: id), abs(current - rate) < 1 { return true }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return false
    }

    // MARK: - Per-device properties

    static func describe(_ id: AudioDeviceID) -> AudioDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }

        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            transportType: transportType(id))
    }

    /// How the device is attached. This is how an iPhone offering itself over
    /// Continuity is told apart from a real microphone — the name is not
    /// reliable, and opening the wrong one takes over the user's phone.
    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String : nil
    }

    /// Total channels across every stream in a scope. A device with zero
    /// input channels can't be recorded from, which is how we tell inputs
    /// from outputs.
    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
