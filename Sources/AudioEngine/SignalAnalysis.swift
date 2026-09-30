import Foundation

/// Measurements used to verify audio actually reached the virtual microphone.
public enum SignalAnalysis {

    public struct Result: Equatable {
        public let rms: Float
        public let hz: Double
    }

    /// RMS level, plus a zero-crossing frequency estimate taken over the
    /// *sounding* region only.
    ///
    /// A recorder always captures for longer than the sound lasts. Counting
    /// crossings across the trailing silence dilutes the rate and reports a
    /// frequency well below the real one, which looks like a pitch bug.
    public static func analyse(_ samples: [Float], sampleRate: Double) -> Result {
        guard !samples.isEmpty else { return Result(rms: 0, hz: 0) }

        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()

        // Anything below a fraction of peak is silence or noise floor.
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return Result(rms: rms, hz: 0) }
        let threshold = peak * 0.1

        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }),
              last > first
        else { return Result(rms: rms, hz: 0) }

        let active = samples[first...last]
        var crossings = 0
        var previous = active[active.startIndex]
        for sample in active.dropFirst() {
            if (previous < 0) != (sample < 0) { crossings += 1 }
            previous = sample
        }

        let seconds = Double(active.count) / sampleRate
        let hz = seconds > 0 ? Double(crossings) / 2.0 / seconds : 0
        return Result(rms: rms, hz: hz)
    }

    /// Energy at one frequency, via the Goertzel algorithm.
    ///
    /// Zero-crossing estimates break down once the live microphone adds room
    /// noise on top of the sound — every noise crossing inflates the count.
    /// Measuring energy at a known frequency is unaffected by broadband noise.
    public static func energy(at frequency: Double, in samples: [Float], sampleRate: Double) -> Float {
        guard samples.count > 1, sampleRate > 0 else { return 0 }

        let k = 2.0 * cos(2.0 * Double.pi * frequency / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + k * s1 - s2
            s2 = s1
            s1 = s0
        }

        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        // Normalise by length so windows of different sizes compare.
        return Float(power / Double(samples.count * samples.count))
    }
}
