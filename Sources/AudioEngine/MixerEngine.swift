import AVFoundation
import CoreAudio
import Foundation
import SoundboardCore

/// Sums the live microphone and soundboard playback into the virtual mic.
///
/// Runs a single AVAudioEngine over the private aggregate device, so mic
/// capture and virtual-mic output share one sample clock.
public final class MixerEngine: @unchecked Sendable {

    public struct Configuration: Sendable {
        public let microphone: AudioDevice
        public let virtualOutput: AudioDevice
        /// Off lets the sound path be tested without microphone permission.
        public let includeMicrophone: Bool

        public init(microphone: AudioDevice, virtualOutput: AudioDevice, includeMicrophone: Bool = true) {
            self.microphone = microphone
            self.virtualOutput = virtualOutput
            self.includeMicrophone = includeMicrophone
        }
    }

    public enum EngineError: Error, CustomStringConvertible {
        case noAudioUnit
        case channelMapFailed(OSStatus)
        case deviceAssignmentFailed(OSStatus)
        case formatUnavailable(Double)
        case deviceAssignmentLost(expected: AudioDeviceID, actual: AudioDeviceID)

        public var description: String {
            switch self {
            case .noAudioUnit: return "AVAudioEngine exposed no audio unit"
            case let .channelMapFailed(s): return "setting input channel map failed (OSStatus \(s))"
            case let .deviceAssignmentFailed(s): return "assigning aggregate device failed (OSStatus \(s))"
            case let .formatUnavailable(rate): return "could not build a 2ch format at \(rate) Hz"
            case let .deviceAssignmentLost(expected, actual):
                return "engine moved off the aggregate device (wanted \(expected), got \(actual))"
            }
        }
    }

    private let configuration: Configuration
    private let aggregateManager: AggregateDeviceManager
    private let engine = AVAudioEngine()
    private let micMixer = AVAudioMixerNode()

    /// One clip plays at a time; triggering a new one cancels whatever is
    /// playing. A single player node with `.interrupts` gives exactly that,
    /// and the node is created up front because building one mid-hotkey would
    /// add latency precisely when it matters.
    private let player = AVAudioPlayerNode()
    private var playerAttached = false

    public private(set) var isRunning = false

    /// The format every internal connection uses — the device's real rate.
    public private(set) var graphFormat: AVAudioFormat?

    /// Diagnostics: what the graph actually ended up as.
    public var engineIsRunning: Bool { engine.isRunning }
    /// What AVAudioEngine itself thinks. It stops on a device configuration
    /// change without telling us, leaving `isRunning` stale and the graph dead.
    public var engineIsActuallyRunning: Bool { engine.isRunning }
    public var mainMixerFormat: AVAudioFormat { engine.mainMixerNode.outputFormat(forBus: 0) }
    public var outputNodeInputFormat: AVAudioFormat { engine.outputNode.inputFormat(forBus: 0) }
    public var playerFormat: AVAudioFormat { player.outputFormat(forBus: 0) }
    /// The gain actually applied to the microphone right now.
    public var currentMicGain: Float { micMixer.outputVolume }
    /// The rate the whole chain is running at.
    public var sampleRate: Double { graphFormat?.sampleRate ?? 0 }
    /// The hardware side of the output node — the device's real format.
    public var hardwareOutputFormat: AVAudioFormat { engine.outputNode.outputFormat(forBus: 0) }

    /// Read back the device the output unit is really on.
    public var assignedDeviceID: AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr ? id : nil
    }

    /// What the real microphone does. Changing it takes effect immediately —
    /// the engine runs continuously, so this must not require a restart.
    public var microphoneMode: MicrophoneMode = .always {
        didSet { applyMicrophoneGain() }
    }

    /// True while a clip is sounding, which `whenIdle` uses to duck the mic.
    public private(set) var isClipPlaying = false

    /// Identifies the current playback so a cancelled clip's late completion
    /// cannot un-duck the microphone underneath its replacement.
    private var playGeneration = 0

    private func applyMicrophoneGain() {
        micMixer.outputVolume = microphoneMode.micGain(isClipPlaying: isClipPlaying)
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.aggregateManager = AggregateDeviceManager(
            configuration: .init(microphone: configuration.microphone,
                                 virtualOutput: configuration.virtualOutput))
    }

    deinit { stop() }

    // MARK: - Lifecycle

    /// Captured during start(). Reading node properties on a RUNNING engine
    /// reconfigures the AUHAL and kills output, so diagnostics are snapshotted
    /// here rather than queried later.
    public struct StartupDiagnostics {
        public var sameAudioUnit = false
        public var inputDevice: AudioDeviceID = 0
        public var outputDevice: AudioDeviceID = 0
        public var aggregateDevice: AudioDeviceID = 0
        public var inputFormat = ""
        public var hardwareFormat = ""
        public var aggregateRateAtStart: Double = 0
        public var defaultInputRate: Double = 0
        public var graphFormat = ""
    }

    public private(set) var diagnostics = StartupDiagnostics()

    public func start() throws {
        guard !isRunning else { return }

        // Only aggregate when the microphone is actually in use. Including it
        // otherwise drags the whole chain to the mic's rate for nothing — a
        // Bluetooth headset would force 16 kHz on a mic we never read.
        let target: AudioDevice
        if configuration.includeMicrophone {
            target = try aggregateManager.create()
        } else {
            AudioDeviceRegistry.setNominalSampleRate(48_000, on: configuration.virtualOutput.id)
            target = configuration.virtualOutput
        }
        let aggregate = target
        diagnostics.aggregateDevice = aggregate.id

        // Order matters. The first touch of inputNode makes AVAudioEngine enable
        // the input side and reconfigure the AUHAL, which silently discards any
        // device already assigned — it substitutes an aggregate of its own. So
        // instantiate the input node first, assign our device after, and assert
        // the assignment survived rather than trusting it.
        // Assign BEFORE the input node is ever referenced. AVAudioEngine caches
        // the input format from whatever device is current at that moment, and
        // the system default input may run at a different rate entirely (a
        // Bluetooth headset at 16 kHz), leaving the graph stuck on a format the
        // aggregate is not using.
        try assignDevice(aggregate.id)
        if configuration.includeMicrophone { _ = engine.inputNode }
        try assignDevice(aggregate.id)
        if configuration.includeMicrophone { try routeMicrophoneChannelOnly() }

        try buildGraph()

        // Building the graph can reconfigure the unit again — but only reassign
        // if it actually drifted. Re-setting the device on an already-correct
        // unit tears down the output connection and renders silence.
        let ensured = AudioUnitDevice.ensure(engine.outputNode.audioUnit, is: aggregate.id)
        guard ensured == noErr else { throw EngineError.deviceAssignmentFailed(ensured) }
        let actual = device(of: engine.outputNode.audioUnit) ?? 0
        guard actual == aggregate.id else {
            throw EngineError.deviceAssignmentLost(expected: aggregate.id, actual: actual)
        }

        // Never touch engine.inputNode unless the microphone is actually in use.
        // Merely reading a property off it enables the input side and resets the
        // AUHAL's device — reading the state is enough to destroy it.
        if configuration.includeMicrophone {
            diagnostics.sameAudioUnit = engine.inputNode.audioUnit == engine.outputNode.audioUnit
            diagnostics.inputDevice = device(of: engine.inputNode.audioUnit) ?? 0
            diagnostics.inputFormat = "out=\(engine.inputNode.outputFormat(forBus: 0)) | in=\(engine.inputNode.inputFormat(forBus: 0))"
        }
        diagnostics.outputDevice = device(of: engine.outputNode.audioUnit) ?? 0
        diagnostics.aggregateRateAtStart = AudioDeviceRegistry.nominalSampleRate(of: aggregate.id) ?? 0
        diagnostics.defaultInputRate = AudioDeviceRegistry.defaultInputDevice()
            .flatMap { AudioDeviceRegistry.nominalSampleRate(of: $0.id) } ?? 0
        diagnostics.hardwareFormat = "\(engine.outputNode.outputFormat(forBus: 0))"
        diagnostics.graphFormat = graphFormat.map { "\($0)" } ?? "none"

        installMeters()

        try engine.start()
        player.play()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        if configuration.includeMicrophone { micMixer.removeTap(onBus: 0) }
        player.stop()
        engine.stop()
        try? aggregateManager.destroy()
        isRunning = false
    }

    // MARK: - Device wiring

    private func device(of unit: AudioUnit?) -> AudioDeviceID? {
        AudioUnitDevice.current(of: unit)
    }

    private func assignDevice(_ id: AudioDeviceID) throws {
        guard engine.outputNode.audioUnit != nil else { throw EngineError.noAudioUnit }
        let status = AudioUnitDevice.assign(engine.outputNode.audioUnit, to: id)
        guard status == noErr else { throw EngineError.deviceAssignmentFailed(status) }
    }

    /// Take ONLY the microphone's channel from the aggregate.
    ///
    /// The aggregate also exposes the virtual device's loopback return. Mixing
    /// that back into our own output is a feedback loop, so the AUHAL channel
    /// map discards everything but channel 0.
    private func routeMicrophoneChannelOnly() throws {
        guard let unit = engine.inputNode.audioUnit else { throw EngineError.noAudioUnit }
        var map: [Int32] = [0]
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output, 1,
            &map, UInt32(MemoryLayout<Int32>.size * map.count))
        guard status == noErr else { throw EngineError.channelMapFailed(status) }
    }

    private func buildGraph() throws {
        let output = engine.outputNode

        // Build at the DEVICE's real rate, not AVAudioEngine's 44.1 kHz default.
        // With playback alone the engine quietly resamples, but one AUHAL cannot
        // run input at 48 kHz and output at 44.1 kHz — engaging the microphone
        // makes the mismatch fatal and the graph renders silence.
        let hardware = output.outputFormat(forBus: 0)
        let channels = max(1, min(hardware.channelCount, 2))
        guard let mixFormat = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                            channels: channels) else {
            throw EngineError.formatUnavailable(hardware.sampleRate)
        }
        self.graphFormat = mixFormat

        if configuration.includeMicrophone {
            engine.attach(micMixer)
            // Connect using the node's INPUT format — the hardware side.
            //
            // `outputFormat(forBus:)` reports a format cached from the system
            // default input device, which is not necessarily the device this
            // engine is on. With a Bluetooth headset as the system default, it
            // reports 16 kHz while the aggregate actually runs at 48 kHz, and
            // connecting at that wrong rate silences the whole graph.
            engine.connect(engine.inputNode, to: micMixer,
                           format: engine.inputNode.inputFormat(forBus: 0))
            engine.connect(micMixer, to: engine.mainMixerNode, format: mixFormat)
            applyMicrophoneGain()
        }

        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: mixFormat)

        engine.connect(engine.mainMixerNode, to: output, format: mixFormat)
    }

    // MARK: - Metering

    public struct Levels: Sendable, Equatable {
        public var microphone: Float = 0
        public var output: Float = 0
    }

    /// Set before start(). Called frequently on an audio thread.
    public var onLevels: (@Sendable (Levels) -> Void)?

    /// Poll this from the UI instead of pushing every audio buffer to the main thread.
    public var currentLevels: Levels { levels.snapshot() }

    private let levels = LevelStore()

    private func installMeters() {
        let store = levels
        let handler = onLevels

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048,
                                        format: engine.mainMixerNode.outputFormat(forBus: 0)) { buffer, _ in
            store.setOutput(Self.rms(buffer))
            handler?(store.snapshot())
        }

        if configuration.includeMicrophone {
            micMixer.installTap(onBus: 0, bufferSize: 2048,
                                format: micMixer.outputFormat(forBus: 0)) { buffer, _ in
                store.setMicrophone(Self.rms(buffer))
            }
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[0][i] * data[0][i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    // MARK: - Diagnostics

    // MARK: - Playback

    /// Play a clip, cancelling whatever was playing.
    ///
    /// `.interrupts` replaces the current buffer on the same node, so there is
    /// never more than one clip sounding. The completion handler of the
    /// cancelled clip may still fire afterwards — callers must tolerate that.
    @discardableResult
    public func play(_ buffer: AVAudioPCMBuffer, gain: Float = 1.0,
                     completion: (@Sendable () -> Void)? = nil) -> Bool {
        guard isRunning else { return false }

        playGeneration += 1
        let generation = playGeneration
        isClipPlaying = true
        applyMicrophoneGain()

        player.volume = gain
        player.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            guard let self else { return }
            // Only the newest playback may restore the microphone.
            if self.playGeneration == generation {
                self.isClipPlaying = false
                self.applyMicrophoneGain()
            }
            completion?()
        }
        if !player.isPlaying { player.play() }
        return true
    }

    /// Convenience: load a file in the engine's current format.
    public func loadSound(_ url: URL) throws -> AVAudioPCMBuffer {
        let format = graphFormat ?? engine.mainMixerNode.outputFormat(forBus: 0)
        return try SoundLibrary.load(url, as: format)
    }

    /// Silence the current clip immediately.
    public func stopAllSounds() {
        playGeneration += 1
        isClipPlaying = false
        applyMicrophoneGain()
        guard player.isPlaying else { return }
        player.stop()
        player.play()
    }
}

/// Levels are written on audio threads and read on the main thread.
final class LevelStore: @unchecked Sendable {
    private var levels = MixerEngine.Levels()
    private let lock = NSLock()

    func setMicrophone(_ v: Float) { lock.lock(); levels.microphone = v; lock.unlock() }
    func setOutput(_ v: Float) { lock.lock(); levels.output = v; lock.unlock() }
    func snapshot() -> MixerEngine.Levels { lock.lock(); defer { lock.unlock() }; return levels }
}
