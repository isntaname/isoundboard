import AVFoundation
import CoreAudio
import Foundation

/// Plays soundboard clips to your own speakers or headphones, so you hear what
/// you just sent to the game.
///
/// Deliberately separate from `MixerEngine`: your output device is a third
/// device on its own sample clock, and one AVAudioEngine drives exactly one
/// device. Keeping it separate also guarantees the microphone never reaches
/// this path — monitoring your own voice back with a few ms of delay is
/// unpleasant, and on speakers it feeds back.
public final class MonitorEngine: @unchecked Sendable {

    public enum MonitorError: Error, CustomStringConvertible {
        case deviceAssignmentFailed(OSStatus)
        case formatUnavailable(Double)

        public var description: String {
            switch self {
            case let .deviceAssignmentFailed(status):
                return "could not route monitoring to that device (OSStatus \(status))"
            case let .formatUnavailable(rate):
                return "could not build a 2ch monitor format at \(rate) Hz"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let device: AudioDevice
    /// One clip at a time, matching the mixer.
    private let player = AVAudioPlayerNode()
    private var playerAttached = false

    public private(set) var isRunning = false

    /// What AVAudioEngine itself thinks. It stops on a device configuration
    /// change without telling us, leaving `isRunning` stale and the graph dead.
    public var engineIsActuallyRunning: Bool { engine.isRunning }
    /// Level of what the monitor is actually rendering, for diagnosis.
    public private(set) var lastPeak: Float = 0
    /// How many times the graph has actually rendered. Zero means the device is
    /// not pulling audio at all, which is different from rendering silence.
    public private(set) var renderCount = 0
    public private(set) var graphFormat: AVAudioFormat?

    /// How loud monitoring is for you. Independent of what the game hears, so
    /// you can keep it quiet without making the clip quiet for everyone else.
    public func resetPeak() { lastPeak = 0; renderCount = 0 }

    /// Is the player node actually running?
    public var playerIsPlaying: Bool { player.isPlaying }

    /// The device the output unit is REALLY on, read back from CoreAudio
    /// rather than assumed from what we asked for.
    public var assignedDeviceID: AudioDeviceID? {
        AudioUnitDevice.current(of: engine.outputNode.audioUnit)
    }

    public var volume: Float = 0.7 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    public init(device: AudioDevice) {
        self.device = device
    }

    deinit { stop() }

    public func start() throws {
        guard !isRunning else { return }

        // Never reference engine.inputNode here, not even to read a property:
        // doing so enables the input side and resets the device assignment.
        let status = AudioUnitDevice.assign(engine.outputNode.audioUnit, to: device.id)
        guard status == noErr else { throw MonitorError.deviceAssignmentFailed(status) }

        // Match the device's real channel count, do not assume stereo.
        //
        // A Bluetooth headset in hands-free mode presents a MONO output. Wiring
        // a 2-channel format to a 1-channel device renders silence, with the
        // engine still reporting that it started and is playing.
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let channels = max(1, min(hardware.channelCount, 2))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: channels) else {
            throw MonitorError.formatUnavailable(hardware.sampleRate)
        }
        graphFormat = format

        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.mainMixerNode.outputVolume = volume

        // Watch what the monitor graph is really producing.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][i])) }
            self?.lastPeak = max(self?.lastPeak ?? 0, peak)
            self?.renderCount += 1
        }

        let ensured = AudioUnitDevice.ensure(engine.outputNode.audioUnit, is: device.id)
        guard ensured == noErr else { throw MonitorError.deviceAssignmentFailed(ensured) }

        try engine.start()
        player.play()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        player.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    @discardableResult
    public func play(_ buffer: AVAudioPCMBuffer, gain: Float = 1.0) -> Bool {
        guard isRunning else { return false }
        player.volume = gain
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
        return true
    }

    public func stopAll() {
        guard player.isPlaying else { return }
        player.stop()
        player.play()
    }

    public func loadSound(_ url: URL) throws -> AVAudioPCMBuffer {
        let format = graphFormat ?? engine.mainMixerNode.outputFormat(forBus: 0)
        return try SoundLibrary.load(url, as: format)
    }
}
