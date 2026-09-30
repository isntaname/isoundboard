import Testing
import Foundation
@testable import AudioEngine

@Suite("SignalAnalysis")
struct SignalAnalysisTests {

    /// A 440 Hz sine at 48 kHz, optionally padded with trailing silence.
    func tone(hz: Double, seconds: Double, silence: Double = 0, rate: Double = 48_000) -> [Float] {
        let active = (0..<Int(seconds * rate)).map {
            Float(sin(2 * .pi * hz * Double($0) / rate)) * 0.5
        }
        return active + [Float](repeating: 0, count: Int(silence * rate))
    }

    @Test("estimates the frequency of a clean tone")
    func estimatesCleanTone() {
        let result = SignalAnalysis.analyse(tone(hz: 440, seconds: 1.0), sampleRate: 48_000)
        #expect(abs(result.hz - 440) < 5)
    }

    @Test("ignores trailing silence when estimating frequency")
    func ignoresTrailingSilence() {
        // The recorder always captures longer than the sound. Averaging the
        // silence in drags the estimate down and reports a false failure.
        let result = SignalAnalysis.analyse(tone(hz: 440, seconds: 1.0, silence: 0.5), sampleRate: 48_000)
        #expect(abs(result.hz - 440) < 5)
    }

    @Test("reports silence as zero, not a spurious frequency")
    func handlesSilence() {
        let result = SignalAnalysis.analyse([Float](repeating: 0, count: 48_000), sampleRate: 48_000)
        #expect(result.rms == 0)
        #expect(result.hz == 0)
    }
}

/// Deterministic noise. Comparing two arbitrary bins of *random* noise against
/// a fixed threshold is flaky — the energy in a narrow bin varies run to run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("ToneDetection")
struct ToneDetectionTests {

    func signal(hz: Double?, seconds: Double, noise: Float, seed: UInt64, rate: Double = 48_000) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0..<Int(seconds * rate)).map { i in
            let tone = hz.map { Float(sin(2 * .pi * $0 * Double(i) / rate)) * 0.5 } ?? 0
            return tone + Float.random(in: -noise...noise, using: &generator)
        }
    }

    func ratio(_ samples: [Float]) -> Float {
        let atTone = SignalAnalysis.energy(at: 440, in: samples, sampleRate: 48_000)
        let offTone = SignalAnalysis.energy(at: 1500, in: samples, sampleRate: 48_000)
        return offTone > 0 ? atTone / offTone : .infinity
    }

    @Test("finds a tone buried in noise that fools zero-crossing")
    func findsToneInNoise() {
        // The live mic adds broadband room noise on top of the soundboard sound.
        // Zero-crossing counts every noise crossing and over-reports badly.
        let samples = signal(hz: 440, seconds: 1.0, noise: 0.15, seed: 1)
        #expect(ratio(samples) > 100)
    }

    @Test("a real tone stands out far more than noise alone does")
    func separatesToneFromNoise() {
        // The meaningful property is the SEPARATION between the two cases, not
        // either value against an arbitrary absolute threshold.
        let withTone = ratio(signal(hz: 440, seconds: 1.0, noise: 0.15, seed: 2))
        let noiseOnly = ratio(signal(hz: nil, seconds: 1.0, noise: 0.15, seed: 2))
        #expect(withTone > noiseOnly * 100)
    }
}
