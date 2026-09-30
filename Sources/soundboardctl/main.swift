import AudioEngine
import Foundation
import InputControl

func listDevices() throws {
    let devices = try AudioDeviceRegistry.allDevices()
    let defIn = AudioDeviceRegistry.defaultInputDevice()
    let defOut = AudioDeviceRegistry.defaultOutputDevice()

    print("\nAudio devices (\(devices.count)):\n")
    for d in devices.sorted(by: { $0.name < $1.name }) {
        var tags: [String] = []
        if d.canRecord { tags.append("in:\(d.inputChannels)") }
        if d.canPlay { tags.append("out:\(d.outputChannels)") }
        if d.id == defIn?.id { tags.append("DEFAULT-IN") }
        if d.id == defOut?.id { tags.append("DEFAULT-OUT") }
        let name = d.name.padding(toLength: max(28, d.name.count), withPad: " ", startingAt: 0)
        let flags = "[\(tags.joined(separator: " "))]"
        let rate = AudioDeviceRegistry.nominalSampleRate(of: d.id).map { "\(Int($0))Hz" } ?? "?"
        print("  \(name)  \(flags.padding(toLength: max(22, flags.count), withPad: " ", startingAt: 0))  \(rate.padding(toLength: 8, withPad: " ", startingAt: 0))  \(d.uid)")
    }
    print("")
}

/// Build the aggregate over the real mic + a virtual device, report what
/// CoreAudio actually produced, then tear it down.
func testAggregate(virtualName: String) throws {
    let devices = try AudioDeviceRegistry.allDevices()

    guard let mic = AudioDeviceRegistry.defaultInputDevice() else {
        print("! no default input device"); return
    }
    guard let virt = DeviceSelection.resolve(uid: nil, name: virtualName, from: devices) else {
        print("! no device named '\(virtualName)'"); return
    }
    guard virt.canPlay else {
        print("! '\(virt.name)' has no output channels — it can't be a virtual mic sink"); return
    }

    print("\n  microphone     : \(mic.name) (in:\(mic.inputChannels))  [clock master]")
    print("  virtual output : \(virt.name) (out:\(virt.outputChannels))\n")

    let manager = AggregateDeviceManager(
        configuration: .init(microphone: mic, virtualOutput: virt))

    let aggregate = try manager.create()
    print("  created aggregate:")
    print("    name : \(aggregate.name)")
    print("    uid  : \(aggregate.uid)")
    print("    in   : \(aggregate.inputChannels) channels")
    print("    out  : \(aggregate.outputChannels) channels")

    // Privacy can only be judged from ANOTHER process — a private aggregate is
    // always visible to its creator. Use `hold` + a second `devices` call.

    guard aggregate.inputChannels > 0, aggregate.outputChannels > 0 else {
        print("\n  ! aggregate lacks both directions — mixer cannot run on it\n")
        try manager.destroy()
        return
    }
    print("\n  Usable: one device with both mic input and virtual output.\n")

    try manager.destroy()
    print("  destroyed cleanly.\n")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "devices" {
case "devices":
    try listDevices()

case "trigger":
    // Does the listener see mouse buttons, and does the injector produce them?
    // Uses a high button number nothing is likely to have bound.
    let button = 6
    let listener = HotkeyListener()
    final class Seen: @unchecked Sendable {
        private var values: [String] = []
        private let lock = NSLock()
        func add(_ v: String) { lock.lock(); values.append(v); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    let seen = Seen()
    listener.onEvent = { event in
        if event.isDown { seen.add("\(event.trigger) synthetic=\(event.isSynthetic)") }
    }
    do { try listener.start() } catch {
        print("! \(error)"); exit(1)
    }
    print("\n  listener started; injecting mouse button \(button)…")

    let injector = KeyInjector(trigger: .mouseButton(button))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        injector.pressDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { injector.release() }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(2.0))

    let observed = seen.all
    print("  observed: \(observed.isEmpty ? "(nothing)" : observed.joined(separator: ", "))")
    let ok = observed.contains { $0.contains("mouseButton(\(button))") }
    print(ok ? "\n  PASS — mouse buttons are seen and can be injected.\n"
             : "\n  FAIL — mouse button not observed.\n")
case "rates":
    for d in try AudioDeviceRegistry.allDevices().sorted(by: { $0.name < $1.name }) {
        let rates = AudioDeviceRegistry.supportedSampleRates(of: d.id)
            .map { String(Int($0)) }.joined(separator: " ")
        print("\n  \(d.name)  [\(d.uid)]")
        print("    current  : \(AudioDeviceRegistry.nominalSampleRate(of: d.id).map { String(Int($0)) } ?? "?")")
        print("    supports : \(rates.isEmpty ? "(none reported)" : rates)")
    }
case "hold":
    // Create the aggregate and keep it alive so another process can look for it.
    let devs = try AudioDeviceRegistry.allDevices()
    guard let mic = AudioDeviceRegistry.defaultInputDevice(),
          let virt = DeviceSelection.resolve(uid: nil, name: "BlackHole 2ch", from: devs) else {
        print("! missing devices"); exit(1)
    }
    let holder = AggregateDeviceManager(configuration: .init(microphone: mic, virtualOutput: virt))
    let agg = try holder.create()
    print("holding aggregate '\(agg.name)' (id \(agg.id)) — pid \(getpid())")
    fflush(stdout)
    Thread.sleep(forTimeInterval: Double(args.count > 2 ? args[2] : "6") ?? 6)
    try holder.destroy()
    print("released")

case "verify":
    try Verify.run(virtualName: args.count > 2 ? args[2] : "BlackHole 2ch",
                   withMic: args.contains("--mic"),
                   micName: args.firstIndex(of: "--input").flatMap {
                       args.indices.contains($0 + 1) ? args[$0 + 1] : nil
                   })

case "claim":
    try Verify.runClaim(virtualName: args.count > 2 ? args[2] : "BlackHole 2ch")

case "duck":
    try Verify.runDuck(virtualName: args.count > 2 ? args[2] : "BlackHole 2ch")

case "interrupt":
    try Verify.runInterrupt(virtualName: args.count > 2 ? args[2] : "BlackHole 2ch")

case "dual":
    try Verify.runDual(virtualName: args.count > 2 ? args[2] : "BlackHole 2ch",
                       withMic: args.contains("--mic"))

case "monitor":
    try Verify.runMonitor(deviceName: args.count > 2 ? args[2] : "BlackHole 2ch")

case "aggregate":
    try testAggregate(virtualName: args.count > 2 ? args[2] : "BlackHole 2ch")
default:
    print("usage: soundboardctl [devices|aggregate|hold|verify [device]] [--mic]")
}
