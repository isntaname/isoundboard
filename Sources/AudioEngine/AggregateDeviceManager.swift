import CoreAudio
import Foundation

/// Builds a private CoreAudio aggregate device pairing the real microphone
/// with the virtual output device.
///
/// Why an aggregate at all: the mixer needs to read the mic and write the
/// virtual mic in one render callback. Two separate devices run on unrelated
/// sample clocks and drift apart within minutes, producing dropouts. An
/// aggregate device makes CoreAudio resample the non-master device to the
/// master's clock for us.
///
/// Why *private*: the device is an implementation detail. A public aggregate
/// shows up in System Settings and every other app's device picker, which is
/// noise the user did not ask for.
///
/// Note it must NOT be channel-split (mic on 1-2, virtual on 3-4) — games read
/// channel 1 only and would never hear the soundboard. The mixing happens in
/// our render callback; the aggregate exists purely for clock sync.
public final class AggregateDeviceManager {

    public struct Configuration: Sendable {
        /// The real microphone. Drift-corrected onto the virtual device's clock.
        public let microphone: AudioDevice
        /// The virtual device the game records from. This is the clock master.
        public let virtualOutput: AudioDevice

        public init(microphone: AudioDevice, virtualOutput: AudioDevice) {
            self.microphone = microphone
            self.virtualOutput = virtualOutput
        }
    }

    private let configuration: Configuration
    private let uid = "io.github.isntaname.isoundboard.aggregate.\(UUID().uuidString)"
    private var deviceID: AudioDeviceID?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit { try? destroy() }

    public var isActive: Bool { deviceID != nil }

    /// The best rate BOTH sub-devices support.
    ///
    /// An aggregate runs every sub-device at one rate, so this cannot simply be
    /// 48 kHz: a Bluetooth headset mic supports only 16 kHz, and asking for
    /// anything else leaves the virtual device at a rate the aggregate is not
    /// actually running at — which reads as silence.
    var targetSampleRate: Double {
        let micRates = AudioDeviceRegistry.supportedSampleRates(of: configuration.microphone.id)
        let virtualRates = AudioDeviceRegistry.supportedSampleRates(of: configuration.virtualOutput.id)

        let shared = virtualRates.filter { rate in
            micRates.contains { abs($0 - rate) < 1 }
        }
        if shared.contains(where: { abs($0 - 48_000) < 1 }) { return 48_000 }
        if let best = shared.max() { return best }
        return AudioDeviceRegistry.nominalSampleRate(of: configuration.virtualOutput.id) ?? 48_000
    }

    @discardableResult
    public func create() throws -> AudioDevice {
        if let existing = deviceID, let device = AudioDeviceRegistry.describe(existing) {
            return device
        }

        // Pin the sub-devices BEFORE building the aggregate.
        //
        // The aggregate inherits whatever rate its members are already at. A
        // Bluetooth headset session can leave the virtual device stuck at
        // 16 kHz, and a later aggregate built from it comes up at 16 kHz on the
        // input side while reporting 48 kHz on the output side — an
        // inconsistent device that produces silence.
        let rate = targetSampleRate
        AudioDeviceRegistry.setNominalSampleRate(rate, on: configuration.virtualOutput.id)
        AudioDeviceRegistry.setNominalSampleRate(rate, on: configuration.microphone.id)

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: "iSoundboard Engine",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            // The VIRTUAL device drives the clock, and the microphone is
            // drift-corrected onto it.
            //
            // The aggregate runs at its master's sample rate. Making the
            // microphone master breaks as soon as it runs at a rate the virtual
            // device cannot: a Bluetooth headset mic negotiates HFP at 16 kHz,
            // BlackHole supports 44.1 kHz and up, and the whole output path goes
            // silent. The virtual device is the destination and has to run at a
            // rate games expect, so it is the one to clock from.
            kAudioAggregateDeviceMasterSubDeviceKey: configuration.virtualOutput.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: configuration.microphone.uid,
                    kAudioSubDeviceDriftCompensationKey: 1,
                ],
                [kAudioSubDeviceUIDKey: configuration.virtualOutput.uid],
            ],
        ]

        if ProcessInfo.processInfo.environment["SB_DEBUG_RATE"] != nil {
            func show(_ label: String, _ id: AudioDeviceID) {
                let now = AudioDeviceRegistry.nominalSampleRate(of: id).map { String(Int($0)) } ?? "?"
                print("  RATE \(label): \(now)")
            }
            print("  RATE target: \(Int(rate))")
            show("mic     ", configuration.microphone.id)
            show("virtual ", configuration.virtualOutput.id)
        }

        var newID = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr, newID != 0 else {
            throw AudioDeviceError.propertyFailed("create aggregate device", status)
        }

        deviceID = newID

        // Pin the aggregate to a rate the game expects.
        //
        // CoreAudio otherwise negotiates the lowest rate every sub-device
        // shares. A Bluetooth headset mic supports only 16 kHz, so the whole
        // aggregate — and the virtual device with it — collapses to 16 kHz and
        // the output path goes silent.
        AudioDeviceRegistry.setNominalSampleRate(rate, on: newID)

        if ProcessInfo.processInfo.environment["SB_DEBUG_RATE"] != nil {
            let agg = AudioDeviceRegistry.nominalSampleRate(of: newID).map { String(Int($0)) } ?? "?"
            let virt = AudioDeviceRegistry.nominalSampleRate(of: configuration.virtualOutput.id).map { String(Int($0)) } ?? "?"
            let mic = AudioDeviceRegistry.nominalSampleRate(of: configuration.microphone.id).map { String(Int($0)) } ?? "?"
            print("  RATE after create -> aggregate \(agg), virtual \(virt), mic \(mic)")
        }

        guard let device = AudioDeviceRegistry.describe(newID) else {
            throw AudioDeviceError.propertyFailed("describe aggregate device", noErr)
        }
        return device
    }

    public func destroy() throws {
        guard let id = deviceID else { return }
        deviceID = nil
        let status = AudioHardwareDestroyAggregateDevice(id)
        guard status == noErr else {
            throw AudioDeviceError.propertyFailed("destroy aggregate device", status)
        }
    }
}
