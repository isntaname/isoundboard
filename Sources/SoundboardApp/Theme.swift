import AppKit
import SwiftUI

// The look borrows from a hardware sampler: rubber pads that light up amber
// while their clip is sounding, keycap-style hotkey labels, and segmented LED
// meters. Everything else stays native macOS.

extension Color {
    /// A colour with separate light and dark appearances.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

enum Palette {
    /// Unlit pad rubber.
    static let pad = Color(light: NSColor(hex: 0xE7E5E1), dark: NSColor(hex: 0x333336))
    static let padHover = Color(light: NSColor(hex: 0xDEDBD6), dark: NSColor(hex: 0x3B3B3F))
    /// The pad's lower lip, which gives it height.
    static let padEdge = Color(light: NSColor(hex: 0xC4C0B9), dark: NSColor(hex: 0x1C1C1E))
    /// Backlit amber of a playing pad.
    static let lit = Color(light: NSColor(hex: 0xFFA41F), dark: NSColor(hex: 0xFFB038))
    static let litHot = Color(light: NSColor(hex: 0xFFC766), dark: NSColor(hex: 0xFFD27F))
    static let litInk = Color(hex: 0x3A2300)
    /// Keycap face.
    static let cap = Color(light: NSColor(hex: 0xFBFAF8), dark: NSColor(hex: 0x4A4A4F))
    static let capEdge = Color(light: NSColor(hex: 0xB9B5AE), dark: NSColor(hex: 0x232326))
    /// An LED that is off.
    static let ledOff = Color(light: NSColor(hex: 0x000000, alpha: 0.10),
                              dark: NSColor(hex: 0xFFFFFF, alpha: 0.10))
    static let ledGreen = Color(light: NSColor(hex: 0x1FA84F), dark: NSColor(hex: 0x3DD26E))
    static let ledAmber = lit
    static let ledRed = Color(light: NSColor(hex: 0xE5372B), dark: NSColor(hex: 0xFF5A4E))
}

// MARK: - LED

/// A small status lamp. Paired with text or an icon wherever it appears, so
/// colour is never the only signal.
struct StatusLED: View {
    enum State { case on, warn, off }
    let state: State

    private var color: Color {
        switch state {
        case .on: return Palette.ledGreen
        case .warn: return Palette.ledAmber
        case .off: return Palette.ledOff
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: state == .off ? .clear : color.opacity(0.7), radius: 3)
            .accessibilityHidden(true)
    }
}

// MARK: - Meter

/// A segmented level meter. Audio RMS is tiny in linear terms, so it is shown
/// on a decibel scale — a linear bar looks dead even when audio is flowing.
struct LEDMeter: View {
    let label: String
    let level: Float
    var segments = 14

    private var lit: Int {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        let fraction = min(1, max(0, (db + 60) / 60))
        return Int((fraction * Double(segments)).rounded())
    }

    private func color(for index: Int) -> Color {
        let position = Double(index + 1) / Double(segments)
        if position > 0.9 { return Palette.ledRed }
        if position > 0.72 { return Palette.ledAmber }
        return Palette.ledGreen
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < lit ? color(for: index) : Palette.ledOff)
                        .frame(width: 4, height: 10)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
    }
}

// MARK: - Keycap

/// A hotkey shown as a physical key. Click to record a new one.
struct KeyCap: View {
    let hotkey: String?
    let recording: Bool
    var placeholder = "Set key"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(recording ? "Press key or button" : (hotkey ?? placeholder))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(hotkey == nil && !recording ? Color.secondary : Color.primary)
                .padding(.horizontal, 7)
                .frame(minWidth: 26, minHeight: 20)
                .background {
                    if hotkey == nil && !recording {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.5),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Palette.capEdge)
                            .offset(y: 1.5)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Palette.cap)
                    }
                }
                .overlay {
                    if recording {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Palette.lit, lineWidth: 1.5)
                    }
                }
                .padding(.bottom, 1.5)
        }
        .buttonStyle(.plain)
        .help("Click, then press a key or mouse button. Esc clears it.")
    }
}
