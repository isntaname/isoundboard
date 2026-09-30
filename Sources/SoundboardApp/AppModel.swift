import AVFoundation
import AppKit
import AudioEngine
import InputControl
import Observation
import SoundboardCore
import SwiftUI

@MainActor
@Observable
final class AppModel {

    // Devices
    var devices: [AudioDevice] = []
    var microphoneUID: String? { didSet { Settings.microphoneUID = microphoneUID; restartEngine() } }
    var virtualUID: String? { didSet { Settings.virtualUID = virtualUID; restartEngine() } }

    // Engine — always running; there is no start/stop.
    var isRunning = false
    var status = "Starting…"

    // Driver
    private(set) var driverStatus: DriverStatus = .unavailable
    private(set) var isChangingDriver = false
    private(set) var driverError: String?
    var usesOurDriver: Bool { virtualDevice?.uid == DriverInstaller.deviceUID }
    var offersDriverInstall: Bool {
        DriverInstaller.offersInstall(status: driverStatus, usesOurDriver: usesOurDriver,
                                      hasVirtualDevice: virtualDevice != nil,
                                      isChanging: isChangingDriver, hasError: driverError != nil)
    }
    var lastError: String?
    var micLevel: Float = 0
    var outputLevel: Float = 0

    /// Point the system default input at the virtual mic, so games find it
    /// without the player configuring anything.
    var claimSystemMicrophone = Settings.claimSystemMicrophone {
        didSet {
            Settings.claimSystemMicrophone = claimSystemMicrophone
            claimSystemMicrophone ? claimMicrophone() : releaseMicrophone()
        }
    }

    var micMode: MicrophoneMode = Settings.micMode {
        didSet {
            Settings.micMode = micMode
            engine?.microphoneMode = micMode
            // Muting must actually let go of the microphone, not merely zero its
            // gain: holding a Bluetooth headset's mic open keeps it in
            // hands-free mode, mono at 16 kHz, for listening as well.
            if (oldValue == .muted) != (micMode == .muted) { restartEngine() }
        }
    }

    // Monitoring
    var monitorEnabled = Settings.monitorEnabled
    var monitorDeviceUID: String? { didSet { Settings.monitorDeviceUID = monitorDeviceUID } }
    var monitorVolume: Float = Settings.monitorVolume {
        didSet {
            Settings.monitorVolume = monitorVolume
            monitor?.volume = monitorVolume
        }
    }

    // Push to talk — the app holds this key down while a clip plays.
    var pttEnabled = Settings.pttEnabled { didSet { Settings.pttEnabled = pttEnabled } }
    var pttTrigger: Trigger = Settings.pttTrigger { didSet { Settings.pttTrigger = pttTrigger } }
    var pttActive = false
    /// True while waiting for the user to press their push-to-talk key.
    var recordingPTTKey = false

    // Library
    var sounds: [Sound] = Library.load() { didSet { Library.save(sounds) } }
    var recordingHotkeyFor: Sound.ID?

    /// A key that silences whatever is playing, from anywhere — including from
    /// inside a full-screen game, where the window's Stop button is unreachable.
    var stopHotkey: Hotkey? = Settings.stopHotkey { didSet { Settings.stopHotkey = stopHotkey } }
    var recordingStopHotkey = false

    /// The clip currently sounding, so its row can offer Stop instead of Play.
    /// Only one plays at a time, so one id is enough.
    var playingSoundID: Sound.ID?
    /// When the current clip (re)started, so a pad can show its progress.
    private(set) var playStartedAt: Date?

    // Permissions
    var permissionStates: [Permission: Bool] = [:]
    var keyboardWorking = false
    let launchedFromTerminal = LaunchContext.isRunningFromTerminal

    private var engine: MixerEngine?
    private var monitor: MonitorEngine?
    private var engineHasMicrophone = false
    private var isStartingEngine = false
    private var isStartingMonitor = false
    /// An engine awaiting teardown, handed to the next start so the two are
    /// serialised on the same background task.
    private var pendingEngineTeardown: MixerEngine?
    var runningSampleRate: Double = 0

    /// A Bluetooth headset microphone forces the hands-free profile, which runs
    /// at 16 kHz. Everything in the chain — including your clips — is limited to
    /// that, so it is worth saying so.
    var lowQualityWarning: String? {
        guard isRunning, runningSampleRate > 0, runningSampleRate < 44_100 else { return nil }
        let name = microphone?.name ?? "This microphone"
        return "\(name) limits everything, clips included, to \(Int(runningSampleRate / 1000)) kHz; pick another microphone for full quality."
    }
    /// The device ids the running engine was built for, so a change in the
    /// system default can be noticed and acted on.
    private var runningDeviceIDs: (mic: AudioDeviceID, virtual: AudioDeviceID)?
    /// Rate and channel count the engines were built for. A Bluetooth headset
    /// switches between stereo A2DP and mono hands-free at runtime, which
    /// invalidates a graph that was built for the other shape.
    private var engineSignature: String?
    private var monitorSignature: String?

    private func signature(_ device: AudioDevice?) -> String {
        guard let device else { return "nil" }
        let rate = Int(AudioDeviceRegistry.nominalSampleRate(of: device.id) ?? 0)
        return "\(device.id):\(rate):\(device.inputChannels)x\(device.outputChannels)"
    }

    private func currentEngineSignature() -> String {
        "\(signature(microphone))|\(signature(virtualDevice))"
    }
    private var buffers: [Sound.ID: AVAudioPCMBuffer] = [:]
    /// Separate cache: the monitor device may run at a different sample rate,
    /// and a buffer whose format does not match its player is silently dropped.
    private var monitorBuffers: [Sound.ID: AVAudioPCMBuffer] = [:]
    private let listener = HotkeyListener()
    private var coordinator = PushToTalkCoordinator(tailDelay: 0.35)
    /// Identifies one *playback*. A cancelled clip's late completion must not
    /// release the key out from under the clip that replaced it.
    private var currentPlayToken: String?
    private var playCounter = 0
    private var ticker: Timer?
    private var tickCount = 0
    private var listenerRetries = 0
    private var activationObserver: (any NSObjectProtocol)?
    private var terminationObserver: (any NSObjectProtocol)?
    private var configurationObserver: (any NSObjectProtocol)?
    private let micClaim = SystemMicrophoneClaim(previousDeviceUID: Settings.previousDefaultInputUID)

    /// nil means "follow the system default", so plugging in a headset takes
    /// effect without the user having to re-pick it.
    ///
    /// Never resolves to the virtual device: once the app claims the system
    /// default input, following it would capture our own output.
    var microphone: AudioDevice? {
        DeviceSelection.microphone(preferredUID: microphoneUID,
                                   systemDefault: effectiveSystemDefaultInput,
                                   virtual: virtualDevice,
                                   from: devices)
    }

    /// What "System Default" means to this app. Once we have taken the system
    /// default input for the virtual device, it means the device we displaced.
    var effectiveSystemDefaultInput: AudioDevice? {
        DeviceSelection.effectiveSystemDefaultInput(
            current: AudioDeviceRegistry.defaultInputDevice(),
            virtual: virtualDevice,
            remembered: micClaim.previousDeviceUID ?? Settings.previousDefaultInputUID,
            from: devices)
    }
    var virtualDevice: AudioDevice? {
        DeviceSelection.resolve(uid: virtualUID, name: nil, from: devices)
    }
    var monitorDevice: AudioDevice? {
        guard let monitorDeviceUID else { return AudioDeviceRegistry.defaultOutputDevice() }
        return DeviceSelection.resolve(uid: monitorDeviceUID, name: nil, from: devices)
            ?? AudioDeviceRegistry.defaultOutputDevice()
    }
    var injector: KeyInjector { KeyInjector(trigger: pttTrigger, isEnabled: pttEnabled) }

    /// Shows the real microphone, never the virtual device we installed as the
    /// system default — labelling it "System Default (BlackHole)" would be a lie.
    var defaultInputName: String {
        effectiveSystemDefaultInput.map { " (\($0.name))" } ?? ""
    }

    /// Real outputs only — monitoring into the virtual device would just feed
    /// the game a second copy of every clip.
    var selectableOutputs: [AudioDevice] {
        devices.filter { $0.canPlay && $0.uid != virtualDevice?.uid }
    }

    /// Real microphones only. The virtual device can record — it is a loopback —
    /// but selecting it would make the app capture its own output.
    var selectableMicrophones: [AudioDevice] {
        devices.filter { $0.canRecord && $0.uid != virtualDevice?.uid }
    }

    var defaultOutputName: String {
        AudioDeviceRegistry.defaultOutputDevice().map { " (\($0.name))" } ?? ""
    }

    init() {
        microphoneUID = Settings.microphoneUID
        virtualUID = Settings.virtualUID
        monitorDeviceUID = Settings.monitorDeviceUID

        refreshDevices()
        recoverSystemMicrophoneIfNeeded()
        refreshPermissions()
        requestPromptablePermissions()
        startListening()
        ensureRunning()

        Diagnostics.log("--- launch: sounds=\(sounds.count) virtual=\(virtualDevice?.name ?? "nil") mic=\(microphone?.name ?? "nil") keyboard=\(keyboardWorking) unmet=\(setupStatus.unmet.map(\.rawValue))")

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPermissions()
                    self?.retryListenerIfNeeded()
                    self?.ensureRunning()
                }
            }

        // AVAudioEngine stops itself when a device changes configuration —
        // a Bluetooth headset switching profile does exactly that. Without
        // handling this the graph is dead while everything still reports fine.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleConfigurationChange() }
            }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseMicrophone() }
            }

        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Devices

    func refreshDevices() {
        devices = (try? AudioDeviceRegistry.allDevices()) ?? []

        // A saved selection pointing at the virtual device would be a feedback
        // loop; earlier builds could persist one. Clear it.
        if let microphoneUID, microphoneUID == virtualDevice?.uid {
            self.microphoneUID = nil
        }

        if virtualDevice == nil {
            virtualUID = DeviceSelection.preferredVirtual(from: devices)?.uid
        }

        driverStatus = DriverInstaller.status(
            installedVersion: DriverInstaller.version(ofDriverAt: DriverInstaller.installedURL),
            bundledVersion: DriverInstaller.version(ofDriverAt: DriverInstaller.bundledURL))
    }

    // MARK: - Engine (always on)

    /// Bring the audio up, and keep it up. Called on launch, on device changes,
    /// when the app is activated, and periodically — so a missing device or a
    /// late permission grant recovers on its own rather than needing a button.
    func ensureRunning() {
        startMonitorIfNeeded()
        guard !isStartingEngine else { return }

        let micGranted = isGranted(.microphone) && micMode != .muted
        if let engine, engine.isRunning {
            if micGranted && !engineHasMicrophone { restartEngine(); return }
            // Follow the system default if the resolved device changed, and
            // rebuild if a device changed shape underneath us.
            if let ids = runningDeviceIDs,
               let mic = microphone, let virt = virtualDevice,
               ids.mic != mic.id || ids.virtual != virt.id {
                restartEngine()
            } else if let built = engineSignature, built != currentEngineSignature() {
                Diagnostics.log("audio device changed shape (\(built) -> \(currentEngineSignature())) — rebuilding")
                restartEngine()
            }
            return
        }

        guard let virt = virtualDevice else {
            status = "No audio driver installed"
            isRunning = false
            return
        }
        guard virt.canPlay else {
            status = "'\(virt.name)' has no output channels and cannot act as a virtual mic."
            isRunning = false
            return
        }
        guard let mic = microphone else {
            // Reached when the only input left is an iPhone, which is never
            // taken automatically. Say so, or it reads as a broken app.
            status = "No microphone available — pick one under Audio in Settings."
            isRunning = false
            return
        }

        // Starting touches the hardware, and a Bluetooth device can take
        // seconds to negotiate. Doing that on the main thread freezes the UI.
        isStartingEngine = true
        status = "Starting audio on \(mic.name)…"
        let configuration = MixerEngine.Configuration(
            microphone: mic, virtualOutput: virt, includeMicrophone: micGranted)
        let mode = micMode
        let previous = pendingEngineTeardown
        pendingEngineTeardown = nil

        Task { [weak self] in
            let outcome: Result<MixerEngine, Error> = await Task.detached(priority: .userInitiated) {
                // Finish tearing the old engine down before touching the device
                // again, or the two contend for it.
                previous?.stop()
                let engine = MixerEngine(configuration: configuration)
                engine.microphoneMode = mode
                do {
                    try engine.start()
                    return .success(engine)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            self.isStartingEngine = false

            switch outcome {
            case let .success(engine):
                self.engine = engine
                self.runningSampleRate = engine.sampleRate
                Diagnostics.log("engine started: mic=\(mic.name) virtual=\(virt.name) rate=\(Int(engine.sampleRate)) micIncluded=\(micGranted)")
                self.engineHasMicrophone = micGranted
                self.runningDeviceIDs = (mic.id, virt.id)
                self.engineSignature = self.currentEngineSignature()
                self.isRunning = true
                self.lastError = nil
                self.claimMicrophone()
                self.status = micGranted
                    ? "Live — games will pick up \(virt.name) automatically"
                    : "Live, but without your microphone — grant Microphone access below."
                self.reloadBuffers()
            case let .failure(error):
                Diagnostics.log("ENGINE FAILED: \(error)")
                self.isRunning = false
                self.runningDeviceIDs = nil
                self.status = "Audio failed to start"
                self.lastError = "\(error)"
            }
        }
    }

    private func restartEngine() {
        guard !isStartingEngine else { return }
        pendingEngineTeardown = engine
        engine = nil
        runningDeviceIDs = nil
        engineSignature = nil
        buffers.removeAll()
        isRunning = false
        ensureRunning()
    }

    private func tick() {
        tickCount += 1
        if tickCount % 15 == 0 { refreshPermissions() }
        // Recover from a device disappearing, or a permission arriving late.
        if tickCount % 30 == 0 {
            refreshDevices()
            ensureRunning()
            refreshMonitorIfDeviceChanged()
            checkEnginesAlive(reason: "health check")
        }

        if !keyboardWorking, listenerRetries % 15 == 0 { retryListenerIfNeeded() }
        else if !keyboardWorking { listenerRetries += 1 }

        // Release push-to-talk once the tail has elapsed.
        let now = Date().timeIntervalSinceReferenceDate
        let wasHeld = coordinator.micShouldBeOpen
        coordinator.tick(at: now)
        if wasHeld && !coordinator.micShouldBeOpen {
            injector.release()
            pttActive = false
        }

        guard let engine, isRunning else { return }
        let levels = engine.currentLevels
        micLevel = max(levels.microphone, micLevel * 0.82)
        outputLevel = max(levels.output, outputLevel * 0.82)
    }


    /// Rebuild whichever engine the system pulled out from under us.
    private func handleConfigurationChange() {
        refreshDevices()
        checkEnginesAlive(reason: "configuration change")
    }

    /// An engine can stop without any notification reaching us, so also poll.
    /// `isRunning` is our own flag; AVAudioEngine's is the truth.
    private func checkEnginesAlive(reason: String) {
        if let engine, isRunning, !engine.engineIsActuallyRunning {
            Diagnostics.log("mixer engine died (\(reason)) — rebuilding")
            restartEngine()
        }
        if let monitor, !monitor.engineIsActuallyRunning, !isStartingMonitor {
            Diagnostics.log("monitor engine died (\(reason)) — rebuilding")
            monitorDeviceChanged()
        }
    }

    // MARK: - System default microphone

    /// A previous run may have been force-quit while holding the default input.
    /// Left alone, every other app would record silence.
    /// Runs unconditionally, not only when something was remembered: the state
    /// to undo is "the virtual device is the system input and we are not the
    /// ones holding it", and a run that crashed before recording anything
    /// leaves exactly that with nothing remembered.
    private func recoverSystemMicrophoneIfNeeded() {
        if SystemMicrophoneClaim.restoreAfterCrash(previousUID: Settings.previousDefaultInputUID,
                                                   virtual: virtualDevice,
                                                   devices: devices) {
            Diagnostics.log("system microphone was left on \(virtualDevice?.name ?? "the virtual device") — handed back")
            Settings.previousDefaultInputUID = nil
        }
    }

    private func claimMicrophone() {
        guard claimSystemMicrophone, let virtual = virtualDevice else { return }
        guard micClaim.claim(virtual) else {
            lastError = "Could not make \(virtual.name) the system microphone."
            return
        }
        Settings.previousDefaultInputUID = micClaim.previousDeviceUID
    }

    private func releaseMicrophone() {
        guard micClaim.isClaimed else { return }
        micClaim.release(from: devices, virtual: virtualDevice)
        Settings.previousDefaultInputUID = nil
    }

    var systemMicrophoneIsOurs: Bool {
        guard let virtual = virtualDevice else { return false }
        return AudioDeviceRegistry.defaultInputDevice()?.uid == virtual.uid
    }

    // MARK: - Driver

    /// Install or update the bundled driver, then switch to it.
    func installDriver() async {
        guard !isChangingDriver else { return }
        isChangingDriver = true
        driverError = nil
        defer { isChangingDriver = false }
        // Let the spinner draw before the password prompt blocks.
        try? await Task.sleep(for: .milliseconds(50))

        switch DriverInstaller.runPrivileged(DriverInstaller.installCommand(
            bundled: DriverInstaller.bundledURL,
            requirement: DriverInstaller.requirement(teamID: DriverInstaller.ownTeamID()))) {
        case .cancelled:
            return
        case .failed(let message):
            driverError = message
            return
        case .done:
            break
        }

        // Core Audio restarts; the device shows up a moment later.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            refreshDevices()
            if devices.contains(where: { $0.uid == DriverInstaller.deviceUID }) {
                // Switch even if a BlackHole was saved: installing is choosing ours.
                virtualUID = DriverInstaller.deviceUID
                ensureRunning()
                return
            }
        }
        driverError = "The driver was installed, but macOS didn't load it. Restart your Mac, then open iSoundboard again."
    }

    func uninstallDriver() async {
        guard !isChangingDriver else { return }
        isChangingDriver = true
        driverError = nil
        defer { isChangingDriver = false }
        // Hand the system microphone back while the device still exists.
        releaseMicrophone()
        try? await Task.sleep(for: .milliseconds(50))

        switch DriverInstaller.runPrivileged(DriverInstaller.uninstallCommand()) {
        case .cancelled:
            claimMicrophone()
            return
        case .failed(let message):
            driverError = message
            claimMicrophone()
            return
        case .done:
            break
        }

        if virtualUID == DriverInstaller.deviceUID { virtualUID = nil }
        try? await Task.sleep(for: .seconds(2))
        refreshDevices()
        ensureRunning()
    }

    // MARK: - Monitoring

    /// Follow the system default output when the user has not pinned one.
    private var runningMonitorDeviceID: AudioDeviceID?

    func refreshMonitorIfDeviceChanged() {
        guard monitorEnabled, let current = monitorDevice else { return }
        let changedDevice = runningMonitorDeviceID != nil && runningMonitorDeviceID != current.id
        // A headset flipping between stereo and hands-free changes rate and
        // channel count without changing device id.
        let changedShape = monitorSignature != nil && monitorSignature != signature(current)
        if changedDevice || changedShape {
            Diagnostics.log("monitor device changed (\(monitorSignature ?? "?") -> \(signature(current))) — rebuilding")
            monitorDeviceChanged()
        }
    }

    func startMonitorIfNeeded() {
        guard monitorEnabled, monitor == nil, !isStartingMonitor,
              let device = monitorDevice, device.canPlay else { return }
        startMonitor(on: device, replacing: nil)
    }

    /// Build the monitor, first finishing any teardown of the one it replaces.
    /// Both halves touch the hardware, so both run off the main thread — and in
    /// that order, or the two engines contend for the same device.
    private func startMonitor(on device: AudioDevice, replacing old: MonitorEngine?) {
        isStartingMonitor = true
        let volume = monitorVolume
        let signature = signature(device)

        Task { [weak self] in
            let engine: MonitorEngine? = await Task.detached(priority: .userInitiated) {
                old?.stop()
                let engine = MonitorEngine(device: device)
                engine.volume = volume
                do {
                    try engine.start()
                    return engine
                } catch {
                    Diagnostics.log("MONITOR FAILED on \(device.name): \(error)")
                    return nil
                }
            }.value

            guard let self else { return }
            self.isStartingMonitor = false
            guard let engine else { return }

            self.monitor = engine
            self.runningMonitorDeviceID = device.id
            self.monitorSignature = signature
            self.monitorBuffers.removeAll()
            let actual = engine.assignedDeviceID
            let actualName = self.devices.first { $0.id == actual }?.name ?? "unknown"
            Diagnostics.log("monitor started: asked for \(device.name) (id \(device.id)), actually on \(actualName) (id \(actual.map(String.init) ?? "nil")) @ \(Int(engine.graphFormat?.sampleRate ?? 0)) Hz, \(engine.graphFormat?.channelCount ?? 0)ch")
            self.reloadBuffers()
        }
    }

    func stopMonitor() {
        let old = monitor
        monitor = nil
        runningMonitorDeviceID = nil
        monitorSignature = nil
        monitorBuffers.removeAll()
        Task.detached(priority: .userInitiated) { old?.stop() }
    }

    func setMonitoring(_ enabled: Bool) {
        monitorEnabled = enabled
        Settings.monitorEnabled = enabled
        enabled ? startMonitorIfNeeded() : stopMonitor()
    }

    func monitorDeviceChanged() {
        guard monitorEnabled, !isStartingMonitor else { return }
        let old = monitor
        monitor = nil
        runningMonitorDeviceID = nil
        monitorSignature = nil
        monitorBuffers.removeAll()

        guard let device = monitorDevice, device.canPlay else {
            Task.detached(priority: .userInitiated) { old?.stop() }
            return
        }
        startMonitor(on: device, replacing: old)
    }

    // MARK: - Sounds

    func addSounds(_ urls: [URL]) {
        for url in urls where SoundLibrary.supportedExtensions.contains(url.pathExtension.lowercased()) {
            sounds.append(Sound(url: url))
        }
        reloadBuffers()
    }

    func remove(_ sound: Sound) {
        sounds.removeAll { $0.id == sound.id }
        buffers[sound.id] = nil
        monitorBuffers[sound.id] = nil
    }

    private func reloadBuffers() {
        for sound in sounds {
            if let engine, isRunning, buffers[sound.id] == nil {
                do { buffers[sound.id] = try engine.loadSound(sound.url) }
                catch {
                    lastError = "\(error)"
                    Diagnostics.log("LOAD FAILED '\(sound.name)': \(error)")
                }
            }
            if let monitor, monitorBuffers[sound.id] == nil {
                if let existing = buffers[sound.id], existing.format == monitor.graphFormat {
                    monitorBuffers[sound.id] = existing
                } else {
                    do { monitorBuffers[sound.id] = try monitor.loadSound(sound.url) }
                    catch { lastError = "Monitoring: \(error)" }
                }
            }
        }
    }

    /// Play a clip. Whatever was playing is cancelled — one at a time.
    func play(_ sound: Sound) {
        startMonitorIfNeeded()
        reloadBuffers()
        var monitorAccepted = false
        if let buffer = monitorBuffers[sound.id], let data = buffer.floatChannelData {
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][i])) }
            Diagnostics.log("  monitor buffer: \(buffer.frameLength) frames, peak \(peak), \(Int(buffer.format.sampleRate))Hz \(buffer.format.channelCount)ch")
        }
        if let monitor, let buffer = monitorBuffers[sound.id] {
            monitor.resetPeak()
            monitorAccepted = monitor.play(buffer, gain: sound.gain)
            // Check what the monitor graph actually rendered.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let monitor = self.monitor else { return }
                Diagnostics.log("  monitor after 400ms: peak=\(monitor.lastPeak) renders=\(monitor.renderCount) playing=\(monitor.playerIsPlaying) engineAlive=\(monitor.engineIsActuallyRunning) vol=\(monitor.volume)")
            }
        }

        // Only what this app did — never what was typed.
        Diagnostics.log("play '\(sound.name)': engine=\(isRunning) buf=\(buffers[sound.id] != nil) monitorAccepted=\(monitorAccepted) monitorBuf=\(monitorBuffers[sound.id] != nil)")
        guard let engine, isRunning, let buffer = buffers[sound.id] else { return }

        let now = Date().timeIntervalSinceReferenceDate

        // Retire the playback being cancelled: its completion may never arrive,
        // and waiting for one that never comes would hold the key down forever.
        if let previous = currentPlayToken {
            coordinator.soundFinished(previous, at: now)
        }

        playCounter += 1
        let token = "play-\(playCounter)"
        currentPlayToken = token
        playingSoundID = sound.id
        playStartedAt = Date()

        // Press push-to-talk before the audio, and hold it through the tail.
        if !coordinator.micShouldBeOpen {
            injector.pressDown()
            pttActive = pttEnabled
        }
        coordinator.soundStarted(token, at: now)

        engine.play(buffer, gain: sound.gain) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.coordinator.soundFinished(token, at: Date().timeIntervalSinceReferenceDate)
                // A cancelled clip's completion still arrives; it must not
                // clear the button state of the clip that replaced it.
                if self.currentPlayToken == token {
                    self.currentPlayToken = nil
                    self.playingSoundID = nil
                }
            }
        }
    }

    func stopAll() {
        engine?.stopAllSounds()
        monitor?.stopAll()
        injector.release()
        pttActive = false
        currentPlayToken = nil
        playingSoundID = nil
        coordinator = PushToTalkCoordinator(tailDelay: 0.35)
    }

    // MARK: - Permissions

    func refreshPermissions() {
        for permission in Permission.allCases {
            permissionStates[permission] = permission.isGranted
        }
    }

    func isGranted(_ permission: Permission) -> Bool { permissionStates[permission] ?? false }

    private func requestPromptablePermissions() {
        guard !launchedFromTerminal else { return }
        for permission in Permission.allCases where permission.canPrompt && !permission.isGranted {
            permission.request()
        }
    }

    func requestPermission(_ permission: Permission) {
        permission.request()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            refreshPermissions()
            retryListenerIfNeeded()
            ensureRunning()
        }
    }

    func revealAppInFinder() { Permission.revealAppInFinder() }

    var hasStaleAuthorization: Bool { isGranted(.inputMonitoring) && !keyboardWorking }

    /// Whether the app is configured enough for the soundboard to work.
    /// Derived from observable state, so the UI follows it automatically.
    var setupStatus: SetupStatus {
        SetupStatus.evaluate(
            hasVirtualDevice: virtualDevice?.canPlay == true,
            audioRunning: isRunning,
            hotkeysWorking: keyboardWorking,
            microphoneGranted: isGranted(.microphone),
            micMode: micMode)
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Hotkeys

    private func startListening() {
        listener.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try listener.start()
            if !keyboardWorking { Diagnostics.log("hotkey listener STARTED") }
            keyboardWorking = true
        } catch {
            if keyboardWorking { Diagnostics.log("hotkey listener FAILED: \(error)") }
            keyboardWorking = false
        }
    }

    private func retryListenerIfNeeded() {
        guard !keyboardWorking, listenerRetries < 600 else { return }
        listenerRetries += 1
        startListening()
    }

    private func handle(_ event: HotkeyListener.Event) {
        guard !event.isSynthetic, event.isDown else { return }

        // Esc while waiting for a key clears that binding instead of taking Esc.
        // Push-to-talk always needs a key, so there it only cancels.
        if event.trigger == .key(53), event.modifiers.isEmpty {
            if recordingPTTKey {
                recordingPTTKey = false
                return
            }
            if recordingStopHotkey {
                stopHotkey = nil
                recordingStopHotkey = false
                return
            }
            if let target = recordingHotkeyFor {
                if let index = sounds.firstIndex(where: { $0.id == target }) {
                    sounds[index].hotkey = nil
                }
                recordingHotkeyFor = nil
                return
            }
        }

        if recordingPTTKey {
            pttTrigger = event.trigger
            pttEnabled = true
            recordingPTTKey = false
            return
        }

        if recordingStopHotkey {
            stopHotkey = Hotkey(trigger: event.trigger, modifiers: event.modifiers)
            recordingStopHotkey = false
            return
        }

        if let target = recordingHotkeyFor {
            if let index = sounds.firstIndex(where: { $0.id == target }) {
                sounds[index].hotkey = Hotkey(trigger: event.trigger, modifiers: event.modifiers)
            }
            recordingHotkeyFor = nil
            return
        }

        // Most specific wins, so Shift-V does not fire a clip bound to plain V.
        // Pressing a clip's own key again restarts it — deliberately not a
        // toggle, so a second press during a clip never leaves the game silent
        // when the user meant to retrigger.
        switch HotkeyMatcher.action(soundHotkeys: sounds.map(\.hotkey),
                                    stopHotkey: stopHotkey,
                                    trigger: event.trigger,
                                    modifiers: event.modifiers) {
        case let .play(index): play(sounds[index])
        case .stopAll: stopAll()
        case nil: break
        }
    }
}

/// Writes what the app is actually doing to a file.
///
/// A GUI app has nowhere to print, so when something "just doesn't work" there
/// is no way to see which stage failed. This closes that gap.
enum Diagnostics {
    static var fileURL: URL {
        AppFolder.file("diagnostic.log")
    }

    /// Keep the file small; it is a rolling record, not an archive.
    private static func trimIfLarge() {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 256_000,
            let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n").suffix(500).joined(separator: "\n")
        try? (kept + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func log(_ message: String) {
        trimIfLarge()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  \(message)\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

/// Small preferences that should survive a relaunch.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    static var micMode: MicrophoneMode {
        get { MicrophoneMode(rawValue: defaults.string(forKey: "micMode") ?? "") ?? .always }
        set { defaults.set(newValue.rawValue, forKey: "micMode") }
    }
    static var monitorEnabled: Bool {
        get { defaults.object(forKey: "monitorEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "monitorEnabled") }
    }
    static var monitorVolume: Float {
        get { defaults.object(forKey: "monitorVolume") as? Float ?? 0.7 }
        set { defaults.set(newValue, forKey: "monitorVolume") }
    }
    static var microphoneUID: String? {
        get { defaults.string(forKey: "microphoneUID") }
        set { defaults.set(newValue, forKey: "microphoneUID") }
    }
    static var virtualUID: String? {
        get { defaults.string(forKey: "virtualUID") }
        set { defaults.set(newValue, forKey: "virtualUID") }
    }
    static var claimSystemMicrophone: Bool {
        get { defaults.object(forKey: "claimSystemMicrophone") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "claimSystemMicrophone") }
    }
    static var previousDefaultInputUID: String? {
        get { defaults.string(forKey: "previousDefaultInputUID") }
        set { defaults.set(newValue, forKey: "previousDefaultInputUID") }
    }
    static var pttEnabled: Bool {
        get { defaults.object(forKey: "pttEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pttEnabled") }
    }
    static var pttTrigger: Trigger {
        get {
            if let data = defaults.data(forKey: "pttTrigger"),
               let trigger = try? JSONDecoder().decode(Trigger.self, from: data) {
                return trigger
            }
            // Migrate the pre-mouse setting.
            return .key(UInt16(defaults.object(forKey: "pttKey") as? Int ?? 9))
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "pttTrigger")
            }
        }
    }
    static var stopHotkey: Hotkey? {
        get {
            guard let data = defaults.data(forKey: "stopHotkey") else { return nil }
            return try? JSONDecoder().decode(Hotkey.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: "stopHotkey")
                return
            }
            defaults.set(data, forKey: "stopHotkey")
        }
    }
    static var monitorDeviceUID: String? {
        get { defaults.string(forKey: "monitorDeviceUID") }
        set { defaults.set(newValue, forKey: "monitorDeviceUID") }
    }
}
