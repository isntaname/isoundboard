import Testing
import AVFoundation
import Foundation
@testable import AudioEngine

@Suite("SoundLibrary")
struct SoundLibraryTests {

    /// Write a real audio file at an awkward rate, to force conversion.
    func makeFile(hz: Double, seconds: Double, rate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![ch][i] = Float(sin(2 * .pi * hz * Double(i) / rate)) * 0.5
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test("converts a file to the engine's format so playback isn't silent")
    func convertsToEngineFormat() throws {
        // Scheduling a buffer whose format differs from the player's connection
        // format fails silently — this is exactly how the mixer produced silence.
        let url = try makeFile(hz: 440, seconds: 0.5, rate: 44_100, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = try SoundLibrary.load(url, as: target)

        #expect(buffer.format.sampleRate == 48_000)
        #expect(buffer.format.channelCount == 2)
    }

    @Test("never truncates, at any duration",
          arguments: [0.25, 0.5, 1.0, 2.0])
    func neverTruncates(seconds: Double) throws {
        let url = try makeFile(hz: 440, seconds: seconds, rate: 44_100, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = try SoundLibrary.load(url, as: target)
        let expected = Int(seconds * 48_000)
        let delta = Int(buffer.frameLength) - expected

        // AVAudioFile.read(into:) used to return short on 1024-frame boundaries,
        // losing an erratic slice of every sound. The only acceptable difference
        // now is the resampler's small constant tail — never a shortfall.
        #expect(delta >= 0, "audio was truncated by \(-delta) frames")
        #expect(delta < 64, "unexpected padding of \(delta) frames")
    }

    @Test("preserves duration across the sample rate change")
    func preservesDuration() throws {
        let url = try makeFile(hz: 440, seconds: 0.5, rate: 44_100, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = try SoundLibrary.load(url, as: target)

        // 0.5s at 48 kHz = 24000 frames, allowing for resampler edge effects.
        #expect(abs(Int(buffer.frameLength) - 24_000) < 64)
    }

    @Test("the converted audio still contains the original tone")
    func preservesContent() throws {
        let url = try makeFile(hz: 440, seconds: 0.5, rate: 44_100, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = try SoundLibrary.load(url, as: target)

        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                count: Int(buffer.frameLength)))
        let atTone = SignalAnalysis.energy(at: 440, in: samples, sampleRate: 48_000)
        let offTone = SignalAnalysis.energy(at: 1500, in: samples, sampleRate: 48_000)
        #expect(atTone > offTone * 10)
    }
}
