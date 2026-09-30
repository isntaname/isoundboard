import AVFoundation
import CoreAudio

/// Binding an AVAudioEngine to a specific CoreAudio device.
///
/// The rules here were expensive to find and fail silently when broken — the
/// engine reports `isRunning == true` and renders internally while the device
/// receives nothing. See docs/audio-findings.md. Shared so the mixer and the
/// monitor cannot drift apart.
enum AudioUnitDevice {

    static func current(of unit: AudioUnit?) -> AudioDeviceID? {
        guard let unit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr ? id : nil
    }

    static func assign(_ unit: AudioUnit?, to id: AudioDeviceID) -> OSStatus {
        guard let unit else { return OSStatus(-1) }
        var deviceID = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0,
                                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Re-assert the device only if it actually drifted.
    ///
    /// Re-setting the device on an already-correct unit tears down the output
    /// connection and renders silence, so this must stay conditional.
    static func ensure(_ unit: AudioUnit?, is id: AudioDeviceID) -> OSStatus {
        guard current(of: unit) != id else { return noErr }
        return assign(unit, to: id)
    }
}
