import AudioEngine
import InputControl
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pad surface

/// Draws a sampler pad: a rubber face sitting on a darker lip. Pressing it
/// sinks the face onto the lip; a playing pad glows amber.
struct PadButtonStyle: ButtonStyle {
    let lit: Bool
    var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        configuration.label
            .background {
                ZStack {
                    shape.fill(lit ? Palette.lit.opacity(0.55) : Palette.padEdge)
                        .offset(y: 2.5)
                    shape.fill(lit
                               ? AnyShapeStyle(LinearGradient(colors: [Palette.litHot, Palette.lit],
                                                              startPoint: .top, endPoint: .bottom))
                               : AnyShapeStyle(hovering ? Palette.padHover : Palette.pad))
                        .offset(y: pressed ? 2 : 0)
                    // A soft highlight along the top edge, as on moulded rubber.
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(lit ? 0.55 : 0.35), .clear],
                                                      startPoint: .top, endPoint: .center),
                                       lineWidth: 1)
                        .offset(y: pressed ? 2 : 0)
                }
                .shadow(color: lit ? Palette.lit.opacity(0.55) : .black.opacity(0.08),
                        radius: lit ? 14 : 1, y: lit ? 0 : 1)
            }
            .offset(y: pressed ? 2 : 0)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .animation(.easeOut(duration: 0.15), value: lit)
    }
}

// MARK: - One pad

struct SoundPad: View {
    @Bindable var model: AppModel
    let sound: Sound
    @State private var hovering = false

    private var isPlaying: Bool { model.playingSoundID == sound.id }
    private var isRecording: Bool { model.recordingHotkeyFor == sound.id }
    private var index: Int? { model.sounds.firstIndex { $0.id == sound.id } }

    var body: some View {
        Button {
            isPlaying ? model.stopAll() : model.play(sound)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(sound.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 6)
                progress
                    .padding(.bottom, 8)
                Text(isPlaying ? "Playing" : sound.durationText)
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .opacity(0.7)
                    // Keeps the row's height when the duration is unknown,
                    // so the key cap lines up across pads.
                    .frame(height: 20, alignment: .leading)
            }
            .foregroundStyle(isPlaying ? Palette.litInk : Color.primary)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PadButtonStyle(lit: isPlaying, hovering: hovering))
        .overlay(alignment: .bottomTrailing) {
            KeyCap(hotkey: sound.hotkey?.displayName, recording: isRecording) {
                model.recordingHotkeyFor = sound.id
            }
            .padding(12)
        }
        .onHover { hovering = $0 }
        .help(sound.name)
        .accessibilityLabel(sound.name)
        .accessibilityValue(isPlaying ? "Playing" : "")
        .contextMenu {
            Button(isPlaying ? "Stop" : "Play") {
                isPlaying ? model.stopAll() : model.play(sound)
            }
            Button("Set Hotkey…") { model.recordingHotkeyFor = sound.id }
            if sound.hotkey != nil, let index {
                Button("Clear Hotkey") { model.sounds[index].hotkey = nil }
            }
            Divider()
            Button("Remove", role: .destructive) { model.remove(sound) }
        }
    }

    /// How far through the clip playback is. Only drawn when the length is
    /// known; otherwise the lit pad alone says it is playing.
    @ViewBuilder
    private var progress: some View {
        if isPlaying, let duration = sound.duration, duration > 0,
           let start = model.playStartedAt {
            TimelineView(.animation) { context in
                let fraction = min(1, max(0, context.date.timeIntervalSince(start) / duration))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.litInk.opacity(0.15))
                        Capsule().fill(Palette.litInk.opacity(0.7))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 3)
            }
        } else {
            Color.clear.frame(height: 3)
        }
    }
}

// MARK: - Board

struct PadBoard: View {
    @Bindable var model: AppModel
    @State private var importing = false
    @State private var dropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.sounds) { sound in
                        SoundPad(model: model, sound: sound)
                    }
                    addPad
                }
            }
            .padding(18)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                stopRow
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .background(.bar)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { model.addSounds(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addSounds(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private var addPad: some View {
        Button { importing = true } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                Text(model.sounds.isEmpty ? "Add sounds, or drop audio files here" : "Add sounds")
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(dropTargeted ? Palette.lit : Color.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(dropTargeted ? Palette.lit : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Stopping needs its own key: while a game is full-screen this window is
    // not reachable, and a clip's own key restarts it rather than stopping it.
    private var stopRow: some View {
        HStack(spacing: 8) {
            Text("Stop key")
                .font(.callout)
            KeyCap(hotkey: model.stopHotkey?.displayName,
                   recording: model.recordingStopHotkey) {
                model.recordingStopHotkey = true
            }
            if model.stopHotkey != nil || model.recordingStopHotkey {
                Button {
                    model.stopHotkey = nil
                    model.recordingStopHotkey = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Clear the stop key")
            }
            Spacer()
            if !model.sounds.isEmpty {
                Text("Pick keys your game doesn't use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
