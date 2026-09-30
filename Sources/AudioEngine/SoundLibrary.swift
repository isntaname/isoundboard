import AVFoundation
import Foundation

public enum SoundLibraryError: Error, CustomStringConvertible {
    case unreadable(URL, String)
    case conversionFailed(URL)

    public var description: String {
        switch self {
        case let .unreadable(url, why): return "could not read \(url.lastPathComponent): \(why)"
        case let .conversionFailed(url): return "could not convert \(url.lastPathComponent) to the engine format"
        }
    }
}

/// Hands the converter successive slices of the source buffer.
///
/// The input block is `@Sendable` and cannot capture mutable state, but the
/// converter invokes it synchronously on the calling thread, so this reference
/// type is only ever touched from one thread at a time.
private final class Feeder: @unchecked Sendable {
    private let source: AVAudioPCMBuffer
    private let format: AVAudioFormat
    private let total: AVAudioFramePosition
    private var position: AVAudioFramePosition = 0

    init(source: AVAudioPCMBuffer, format: AVAudioFormat) {
        self.source = source
        self.format = format
        self.total = AVAudioFramePosition(source.frameLength)
    }

    func next(_ requested: AVAudioPacketCount,
              _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let remaining = total - position
        guard remaining > 0 else {
            status.pointee = .endOfStream
            return nil
        }

        let count = AVAudioFrameCount(min(AVAudioFramePosition(requested), remaining))
        guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let destination = slice.floatChannelData,
              let origin = source.floatChannelData
        else {
            status.pointee = .endOfStream
            return nil
        }

        slice.frameLength = count
        for ch in 0..<Int(format.channelCount) {
            memcpy(destination[ch], origin[ch] + Int(position), Int(count) * MemoryLayout<Float>.size)
        }

        position += AVAudioFramePosition(count)
        status.pointee = .haveData
        return slice
    }
}

/// Decodes sound files into buffers the mixer can schedule.
public enum SoundLibrary {

    /// Anything AVAudioFile can open.
    public static let supportedExtensions = ["wav", "mp3", "m4a", "aiff", "aif", "caf", "flac", "aac", "mp4"]

    /// Decode a file fully into memory, converted to the engine's format.
    ///
    /// Converting at load time matters twice over: scheduling a buffer whose
    /// format differs from the player's connection format fails silently, and
    /// decoding during a hotkey press would add latency exactly when it hurts.
    public static func load(_ url: URL, as target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SoundLibraryError.unreadable(url, error.localizedDescription)
        }

        let sourceFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { throw SoundLibraryError.conversionFailed(url) }

        // AVAudioFile.read(into:) returns SHORT — it stops on whole 1024-frame
        // chunk boundaries and does not guarantee reading the whole file in one
        // call. Loop until the file position reaches its length, or every sound
        // loses an erratic slice of its tail.
        var filled: AVAudioFrameCount = 0
        while filled < frames {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                               frameCapacity: frames - filled) else { break }
            do {
                try file.read(into: chunk)
            } catch {
                throw SoundLibraryError.unreadable(url, error.localizedDescription)
            }
            guard chunk.frameLength > 0 else { break }

            if let destination = sourceBuffer.floatChannelData, let origin = chunk.floatChannelData {
                for ch in 0..<Int(sourceFormat.channelCount) {
                    memcpy(destination[ch] + Int(filled), origin[ch],
                           Int(chunk.frameLength) * MemoryLayout<Float>.size)
                }
            }
            filled += chunk.frameLength
        }
        sourceBuffer.frameLength = filled

        if sourceFormat == target { return sourceBuffer }

        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw SoundLibraryError.conversionFailed(url)
        }
        // Without this the resampler's pre-roll swallows ~12 ms of every sound.
        converter.primeMethod = .none


        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw SoundLibraryError.conversionFailed(url)
        }

        // Two independent requirements, both mandatory:
        //
        //  1. Feed the converter the packet count it ASKS for. Handing it the
        //     whole source buffer makes it take only what it requested and drop
        //     the remainder.
        //  2. Call convert repeatedly until endOfStream. One call does not emit
        //     all output; how much it returns varies with internal chunking.
        //
        // Satisfying only one of the two truncates each sound by an erratic
        // amount. (convert(to:from:) is not an option — it cannot resample.)
        let feeder = Feeder(source: sourceBuffer, format: sourceFormat)
        let supply: AVAudioConverterInputBlock = { requested, status in
            feeder.next(requested, status)
        }

        var written: AVAudioFrameCount = 0
        let targetChannels = Int(target.channelCount)

        while written < capacity {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
                throw SoundLibraryError.conversionFailed(url)
            }

            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError, withInputFrom: supply)

            if let conversionError {
                throw SoundLibraryError.unreadable(url, conversionError.localizedDescription)
            }

            if chunk.frameLength > 0 {
                let count = min(chunk.frameLength, capacity - written)
                if let source = chunk.floatChannelData, let destination = output.floatChannelData {
                    for ch in 0..<targetChannels {
                        memcpy(destination[ch] + Int(written), source[ch],
                               Int(count) * MemoryLayout<Float>.size)
                    }
                }
                written += count
            }

            if status == .endOfStream || status == .error { break }
            if chunk.frameLength == 0 { break }
        }

        output.frameLength = written


        guard output.frameLength > 0 else { throw SoundLibraryError.conversionFailed(url) }
        return output
    }
}
