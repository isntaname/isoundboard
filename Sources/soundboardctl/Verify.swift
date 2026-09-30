import AVFoundation
import AVFAudio
import AudioEngine
import Foundation

/// End-to-end proof: push a known tone through the mixer into the virtual
/// device, record the virtual device's loopback in a second engine, and check
/// the tone actually arrived. The recorder hears exactly what the game hears.
enum Verify {

    static func tone(frequency: Double, seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        guard let channels = buffer.floatChannelData else { return nil }
        let step = 2.0 * Double.pi * frequency / format.sampleRate
        for frame in 0..<Int(frames) {
            // Fade the edges so the analyser doesn't measure click transients.
            let progress = Double(frame) / Double(frames)
            let envelope = min(1.0, min(progress, 1.0 - progress) * 20.0)
            let sample = Float(sin(step * Double(frame)) * 0.5 * envelope)
            for ch in 0..<Int(format.channelCount) { channels[ch][frame] = sample }
        }
        return buffer
    }

    static func run(virtualName: String, withMic: Bool, micName: String? = nil) throws {
        let devices = try AudioDeviceRegistry.allDevices()
        let resolvedMic = micName.flatMap { DeviceSelection.resolve(uid: nil, name: $0, from: devices) }
            ?? AudioDeviceRegistry.defaultInputDevice()
        guard let mic = resolvedMic else {
            print("! no input device"); return
        }
        guard let virt = DeviceSelection.resolve(uid: nil, name: virtualName, from: devices) else {
            print("! no device named '\(virtualName)'"); return
        }

        print("\n  mic    <- \(mic.name) @ \(AudioDeviceRegistry.nominalSampleRate(of: mic.id).map { String(Int($0)) } ?? "?") Hz")
        print("  mixer  -> \(virt.name) (the game's microphone)")
        print("  record <- \(virt.name) loopback\n")

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        let authName: String
        switch auth {
        case .authorized: authName = "authorized"
        case .denied: authName = "DENIED"
        case .restricted: authName = "restricted"
        case .notDetermined: authName = "not determined"
        @unknown default: authName = "unknown"
        }
        print("  microphone permission: \(authName)")

        let mixer = MixerEngine(configuration: .init(
            microphone: mic, virtualOutput: virt, includeMicrophone: withMic))
        let internalPeak = Peak()
        try mixer.start()
        defer { mixer.stop() }
        print("  mixer running (mic \(withMic ? "ON" : "off"))")
        let d = mixer.diagnostics
        print("\n  --- mixer engine (snapshotted at start) ---")
        print("    input AU == output AU : \(d.sameAudioUnit)")
        print("    input AU device       : \(d.inputDevice)")
        print("    output AU device      : \(d.outputDevice)")
        print("    aggregate device      : \(d.aggregateDevice)   (BlackHole=\(virt.id))")
        print("    input format          : \(d.inputFormat)")
        print("    hardware format       : \(d.hardwareFormat)")
        print("    aggregate rate NOW    : \(Int(d.aggregateRateAtStart))")
        print("    system default in rate: \(Int(d.defaultInputRate))")
        print("    engine.isRunning   : \(mixer.engineIsRunning)")
        print("    assigned device id : \(mixer.assignedDeviceID.map(String.init) ?? "nil")  (BlackHole=\(virt.id))")
        print("    mainMixer format   : \(mixer.mainMixerFormat)")
        print("    outputNode input   : \(mixer.outputNodeInputFormat)")
        print("    player format      : \(mixer.playerFormat)")
        print("    HARDWARE output    : \(mixer.hardwareOutputFormat)")

        // Separate engine recording the virtual device — a stand-in for the game.
        let recorder = AVAudioEngine()
        guard let unit = recorder.inputNode.audioUnit else { print("! no input unit"); return }
        var deviceID = virt.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { print("! recorder device assignment failed (\(status))"); return }

        let inFormat = recorder.inputNode.inputFormat(forBus: 0)
        var readback = AudioDeviceID(0)
        var rbSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &readback, &rbSize)
        print("\n  --- recorder ---")
        print("    device id          : \(readback)  (BlackHole=\(virt.id))")
        print("    input format       : \(inFormat)")
        let captured = Captured()
        recorder.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            captured.append(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
        }
        try recorder.start()
        defer { recorder.stop(); recorder.inputNode.removeTap(onBus: 0) }

        // Baseline: nothing playing. Should be near silence.
        // Sample the engine's own microphone meter, to tell "silent room" apart
        // from "microphone not reaching the graph at all".
        var micPeak: Float = 0
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.05)
            micPeak = max(micPeak, mixer.currentLevels.microphone)
        }
        print(String(format: "  mic level (engine): %.6f  %@", micPeak,
                     micPeak > 0.000001 ? "<- microphone IS being captured" : "<- NO microphone signal"))

        let silence = SignalAnalysis.analyse(captured.take(), sampleRate: inFormat.sampleRate)
        print(String(format: "  idle level        : RMS %.5f", silence.rms))

        guard let buffer = tone(frequency: 440, seconds: 1.0, format: mixer.mainMixerFormat) else {
            print("! could not build tone"); return
        }
        var peak: Float = 0
        if let d = buffer.floatChannelData {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(d[0][i])) }
        }
        print("\n  --- tone buffer ---")
        print("    format             : \(buffer.format)")
        print("    frames             : \(buffer.frameLength), peak \(peak)")

        let scheduled = mixer.play(buffer, gain: 0.8)
        print("    play() accepted    : \(scheduled)")
        Thread.sleep(forTimeInterval: 1.2)

        internalPeak.observe(mixer.currentLevels.output)
        print("    mixer's OWN output : peak RMS \(internalPeak.value)  <- inside the graph")
        let raw = captured.take()
        print("\n  --- capture ---")
        print("    frames captured    : \(raw.count)")
        let result = SignalAnalysis.analyse(raw, sampleRate: inFormat.sampleRate)
        print(String(format: "  with 440 Hz tone  : RMS %.5f, ~%.0f Hz", result.rms, result.hz))

        // Goertzel, not zero-crossing: with the live mic on, room noise sits on
        // top of the tone and breaks crossing-based pitch estimates.
        let atTone = SignalAnalysis.energy(at: 440, in: raw, sampleRate: inFormat.sampleRate)
        let offTone = SignalAnalysis.energy(at: 1500, in: raw, sampleRate: inFormat.sampleRate)
        let ratio = offTone > 0 ? atTone / offTone : .infinity
        print(String(format: "  440 Hz vs off-tone: %.1fx", ratio))

        let audible = result.rms > max(0.01, silence.rms * 4)

        // With no signal at all, off-tone energy is 0 and the ratio is infinite.
        // Requiring audibility first stops silence being reported as a match.
        let correctPitch = audible && ratio > 10

        print("")
        print("  tone reached the virtual mic : \(audible ? "YES" : "NO")")
        print("  it is the 440 Hz tone        : \(correctPitch ? "YES" : "NO")")
        if withMic {
            print("  live mic also flowing        : \(silence.rms > 0.00002 ? "YES (idle RMS \(silence.rms))" : "no signal")")
        }
        print(audible && correctPitch
              ? "\n  PASS — a game recording this device would hear the soundboard.\n"
              : "\n  FAIL — see above.\n")
    }
}

final class Peak: @unchecked Sendable {
    private var peak: Float = 0
    private let lock = NSLock()
    func observe(_ v: Float) { lock.lock(); peak = max(peak, v); lock.unlock() }
    var value: Float { lock.lock(); defer { lock.unlock() }; return peak }
}

/// Thread-safe sample accumulator; the tap runs on a realtime thread.
final class Captured: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ new: [Float]) {
        lock.lock(); samples.append(contentsOf: new); lock.unlock()
    }

    func take() -> [Float] {
        lock.lock(); let out = samples; samples.removeAll(); lock.unlock()
        return out
    }
}

/// Verify the monitor path independently: point monitoring at a device we can
/// record (BlackHole), then check the tone actually arrived there.
extension Verify {
    static func runMonitor(deviceName: String) throws {
        let devices = try AudioDeviceRegistry.allDevices()
        // A Bluetooth headset appears twice under one name — input and output.
        // Search only the playable ones.
        guard let target = DeviceSelection.resolve(uid: nil, name: deviceName,
                                                   from: devices.filter(\.canPlay)) else {
            print("! no playable device named '\(deviceName)'"); return
        }

        print("\n  monitor -> \(target.name)")
        print("  record  <- \(target.name)\n")

        let monitor = MonitorEngine(device: target)
        monitor.volume = 1.0
        try monitor.start()
        defer { monitor.stop() }
        print("  monitor running, graph format: \(monitor.graphFormat.map { "\($0)" } ?? "none")")
        let deviceChannels = min(target.outputChannels, 2)
        let graphChannels = Int(monitor.graphFormat?.channelCount ?? 0)
        print("  device output channels: \(target.outputChannels), graph channels: \(graphChannels)"
              + (graphChannels == deviceChannels ? "  ok" : "  MISMATCH — will render silence"))

        let recorder = AVAudioEngine()
        guard let unit = recorder.inputNode.audioUnit else { print("! no input unit"); return }
        var deviceID = target.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { print("! recorder assignment failed (\(status))"); return }

        let inFormat = recorder.inputNode.inputFormat(forBus: 0)
        let captured = Captured()
        recorder.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            captured.append(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
        }
        try recorder.start()
        defer { recorder.stop(); recorder.inputNode.removeTap(onBus: 0) }

        Thread.sleep(forTimeInterval: 0.4)
        let idle = SignalAnalysis.analyse(captured.take(), sampleRate: inFormat.sampleRate)
        print(String(format: "  idle level        : RMS %.5f", idle.rms))

        guard let format = monitor.graphFormat,
              let buffer = tone(frequency: 440, seconds: 1.0, format: format) else {
            print("! could not build tone"); return
        }
        print("  play() accepted   : \(monitor.play(buffer))")
        Thread.sleep(forTimeInterval: 1.3)

        let raw = captured.take()
        let result = SignalAnalysis.analyse(raw, sampleRate: inFormat.sampleRate)
        let atTone = SignalAnalysis.energy(at: 440, in: raw, sampleRate: inFormat.sampleRate)
        let offTone = SignalAnalysis.energy(at: 1500, in: raw, sampleRate: inFormat.sampleRate)
        let ratio = offTone > 0 ? atTone / offTone : .infinity

        print(String(format: "  with tone         : RMS %.5f, ~%.0f Hz", result.rms, result.hz))
        let audible = result.rms > max(0.01, idle.rms * 4)
        print("")
        print(audible && ratio > 10
              ? "  PASS — monitoring reaches the chosen output device.\n"
              : "  FAIL — nothing arrived at the monitor device.\n")
    }
}

/// The realistic configuration: mixer feeding the virtual mic while monitoring
/// plays to a different output device at the same time. Two engines on two
/// devices with unrelated clocks is where things quietly stop working.
extension Verify {
    static func runDual(virtualName: String, withMic: Bool = false) throws {
        let devices = try AudioDeviceRegistry.allDevices()
        guard let mic = AudioDeviceRegistry.defaultInputDevice(),
              let virt = DeviceSelection.resolve(uid: nil, name: virtualName, from: devices),
              let out = AudioDeviceRegistry.defaultOutputDevice() else {
            print("! missing devices"); return
        }

        print("\n  mixer   -> \(virt.name)  (the game)")
        print("  monitor -> \(out.name)  (you)")
        print("  record  <- \(virt.name)\n")

        let mixer = MixerEngine(configuration: .init(
            microphone: mic, virtualOutput: virt, includeMicrophone: withMic))
        try mixer.start()
        defer { mixer.stop() }
        print("  mixer mic: \(withMic ? mic.name : "off"), graph \(Int(mixer.sampleRate)) Hz")

        let monitor = MonitorEngine(device: out)
        monitor.volume = 0.12   // audible but unobtrusive
        try monitor.start()
        defer { monitor.stop() }
        print("  both engines started: mixer \(mixer.isRunning), monitor \(monitor.isRunning)")
        print("  monitor graph: \(monitor.graphFormat.map { "\(Int($0.sampleRate)) Hz" } ?? "none")")

        let recorder = AVAudioEngine()
        guard let unit = recorder.inputNode.audioUnit else { print("! no input unit"); return }
        var deviceID = virt.id
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &deviceID,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            print("! recorder assignment failed"); return
        }
        let inFormat = recorder.inputNode.inputFormat(forBus: 0)
        let captured = Captured()
        recorder.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            captured.append(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
        }
        try recorder.start()
        defer { recorder.stop(); recorder.inputNode.removeTap(onBus: 0) }

        Thread.sleep(forTimeInterval: 0.4)
        let idle = SignalAnalysis.analyse(captured.take(), sampleRate: inFormat.sampleRate)

        guard let mixFormat = mixer.graphFormat,
              let monFormat = monitor.graphFormat,
              let toGame = tone(frequency: 440, seconds: 1.0, format: mixFormat),
              let toEars = tone(frequency: 440, seconds: 1.0, format: monFormat) else {
            print("! could not build tones"); return
        }

        // One trigger, both destinations — what the app does on a hotkey.
        let a = mixer.play(toGame, gain: 0.8)
        let b = monitor.play(toEars, gain: 0.8)
        print("  mixer accepted: \(a), monitor accepted: \(b)  (you should hear a beep)")
        Thread.sleep(forTimeInterval: 1.3)

        let raw = captured.take()
        let result = SignalAnalysis.analyse(raw, sampleRate: inFormat.sampleRate)
        let atTone = SignalAnalysis.energy(at: 440, in: raw, sampleRate: inFormat.sampleRate)
        let offTone = SignalAnalysis.energy(at: 1500, in: raw, sampleRate: inFormat.sampleRate)
        let ratio = offTone > 0 ? atTone / offTone : .infinity

        print(String(format: "  idle RMS %.5f -> with tone RMS %.5f (~%.0f Hz)",
                     idle.rms, result.rms, result.hz))

        let reached = result.rms > max(0.01, idle.rms * 4) && ratio > 10
        print("")
        print(reached
              ? "  PASS — the game still gets the sound while you monitor it elsewhere.\n"
              : "  FAIL — running the monitor broke the path to the virtual mic.\n")
    }
}

/// Prove clips do not stack: start a long 440 Hz clip, interrupt it with an
/// 880 Hz one, and check the 440 is actually GONE afterwards rather than
/// continuing underneath.
extension Verify {
    static func runInterrupt(virtualName: String) throws {
        let devices = try AudioDeviceRegistry.allDevices()
        guard let mic = AudioDeviceRegistry.defaultInputDevice(),
              let virt = DeviceSelection.resolve(uid: nil, name: virtualName, from: devices) else {
            print("! missing devices"); return
        }

        let mixer = MixerEngine(configuration: .init(
            microphone: mic, virtualOutput: virt, includeMicrophone: false))
        try mixer.start()
        defer { mixer.stop() }

        let recorder = AVAudioEngine()
        guard let unit = recorder.inputNode.audioUnit else { print("! no input unit"); return }
        var deviceID = virt.id
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &deviceID,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            print("! recorder assignment failed"); return
        }
        let rate = recorder.inputNode.inputFormat(forBus: 0).sampleRate
        let captured = Captured()
        recorder.inputNode.installTap(onBus: 0, bufferSize: 1024,
                                      format: recorder.inputNode.inputFormat(forBus: 0)) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            captured.append(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
        }
        try recorder.start()
        defer { recorder.stop(); recorder.inputNode.removeTap(onBus: 0) }

        guard let format = mixer.graphFormat,
              let low = tone(frequency: 440, seconds: 4.0, format: format),
              let high = tone(frequency: 880, seconds: 2.0, format: format) else {
            print("! could not build tones"); return
        }

        print("\n  playing 440 Hz for 4s…")
        mixer.play(low, gain: 0.8)
        Thread.sleep(forTimeInterval: 0.3)
        _ = captured.take()                       // discard the onset
        Thread.sleep(forTimeInterval: 0.7)
        let before = captured.take()

        print("  interrupting with 880 Hz after ~1s…")
        mixer.play(high, gain: 0.8)
        Thread.sleep(forTimeInterval: 0.4)
        _ = captured.take()                       // discard the transition
        Thread.sleep(forTimeInterval: 0.7)
        let after = captured.take()

        func report(_ label: String, _ samples: [Float]) -> (Float, Float) {
            let at440 = SignalAnalysis.energy(at: 440, in: samples, sampleRate: rate)
            let at880 = SignalAnalysis.energy(at: 880, in: samples, sampleRate: rate)
            print(String(format: "  %@: 440Hz %.3e   880Hz %.3e", label, at440, at880))
            return (at440, at880)
        }

        print("")
        let (b440, b880) = report("before interrupt", before)
        let (a440, a880) = report("after interrupt ", after)

        let firstPlayed = b440 > b880 * 10
        let secondPlayed = a880 > a440 * 10
        let firstStopped = a440 < b440 / 10

        print("")
        print("  first clip played           : \(firstPlayed ? "YES" : "NO")")
        print("  second clip replaced it     : \(secondPlayed ? "YES" : "NO")")
        print("  first clip actually stopped : \(firstStopped ? "YES" : "NO — they overlapped!")")
        print(firstPlayed && secondPlayed && firstStopped
              ? "\n  PASS — one clip at a time; the new one cancels the old.\n"
              : "\n  FAIL — see above.\n")
    }
}

/// Check each microphone mode does what it claims, including that ducking
/// recovers after a clip ends and after one clip cancels another.
extension Verify {
    static func runDuck(virtualName: String) throws {
        let devices = try AudioDeviceRegistry.allDevices()
        guard let mic = AudioDeviceRegistry.defaultInputDevice(),
              let virt = DeviceSelection.resolve(uid: nil, name: virtualName, from: devices) else {
            print("! missing devices"); return
        }

        let mixer = MixerEngine(configuration: .init(
            microphone: mic, virtualOutput: virt, includeMicrophone: true))
        try mixer.start()
        defer { mixer.stop() }

        guard let format = mixer.graphFormat,
              let clip = tone(frequency: 440, seconds: 1.0, format: format),
              let longClip = tone(frequency: 660, seconds: 3.0, format: format) else {
            print("! could not build tones"); return
        }

        var failures = 0
        func check(_ label: String, _ actual: Float, _ expected: Float) {
            let ok = abs(actual - expected) < 0.01
            if !ok { failures += 1 }
            print(String(format: "  %@ gain %.2f (expected %.2f)  %@",
                         label.padding(toLength: 34, withPad: " ", startingAt: 0),
                         actual, expected, ok ? "ok" : "MISMATCH"))
        }

        print("\n  mode: muted")
        mixer.microphoneMode = .muted
        check("idle", mixer.currentMicGain, 0)
        mixer.play(clip); Thread.sleep(forTimeInterval: 0.3)
        check("during a clip", mixer.currentMicGain, 0)
        Thread.sleep(forTimeInterval: 1.0)

        print("\n  mode: always")
        mixer.microphoneMode = .always
        check("idle", mixer.currentMicGain, 1)
        mixer.play(clip); Thread.sleep(forTimeInterval: 0.3)
        check("during a clip", mixer.currentMicGain, 1)
        Thread.sleep(forTimeInterval: 1.2)

        print("\n  mode: whenIdle")
        mixer.microphoneMode = .whenIdle
        check("idle", mixer.currentMicGain, 1)
        mixer.play(clip); Thread.sleep(forTimeInterval: 0.3)
        check("during a clip", mixer.currentMicGain, 0)
        Thread.sleep(forTimeInterval: 1.3)
        check("after the clip ends", mixer.currentMicGain, 1)

        print("\n  whenIdle, interrupted clip")
        mixer.play(longClip); Thread.sleep(forTimeInterval: 0.3)
        check("during the long clip", mixer.currentMicGain, 0)
        mixer.play(clip)                       // cancels the long clip
        Thread.sleep(forTimeInterval: 0.3)
        check("during the replacement", mixer.currentMicGain, 0)
        Thread.sleep(forTimeInterval: 1.3)
        check("after the replacement ends", mixer.currentMicGain, 1)

        print("\n  whenIdle, stopped manually")
        mixer.play(longClip); Thread.sleep(forTimeInterval: 0.3)
        check("during", mixer.currentMicGain, 0)
        mixer.stopAllSounds(); Thread.sleep(forTimeInterval: 0.2)
        check("after stop", mixer.currentMicGain, 1)

        print(failures == 0
              ? "\n  PASS — every microphone mode behaves as described.\n"
              : "\n  FAIL — \(failures) mismatch(es).\n")
    }
}

/// Exercise the full claim/restore cycle on the real system. The restore half
/// matters most: leaving the virtual device as the system default input would
/// make every other app record silence.
extension Verify {
    static func runClaim(virtualName: String) throws {
        let devices = try AudioDeviceRegistry.allDevices()
        guard let virtual = DeviceSelection.resolve(uid: nil, name: virtualName, from: devices) else {
            print("! no device named '\(virtualName)'"); return
        }

        func currentDefault() -> String {
            AudioDeviceRegistry.defaultInputDevice()?.name ?? "(none)"
        }

        let before = currentDefault()
        print("\n  default input before : \(before)")

        let claim = SystemMicrophoneClaim()
        guard claim.claim(virtual) else { print("\n  FAIL — could not claim\n"); return }
        Thread.sleep(forTimeInterval: 0.4)

        let during = currentDefault()
        print("  default input during : \(during)")
        print("  remembered previous  : \(claim.previousDeviceUID ?? "(none)")")

        claim.release(from: devices, virtual: virtual)
        Thread.sleep(forTimeInterval: 0.4)
        let after = currentDefault()
        print("  default input after  : \(after)")

        let claimed = during == virtual.name
        let restored = after == before
        print("")
        print("  became the system microphone : \(claimed ? "YES" : "NO")")
        print("  gave it back on release      : \(restored ? "YES" : "NO — left as \(after)!")")
        print(claimed && restored
              ? "\n  PASS — claim and restore both work.\n"
              : "\n  FAIL — see above.\n")
    }
}
