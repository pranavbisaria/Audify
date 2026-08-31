import AppKit
import AudifyKit
import SwiftUI

/// App icons are looked up once and kept in a size-limited cache.
///
/// `NSWorkspace.icon(forFile:)` hits the filesystem, and the mixer can redraw many times a second
/// while a slider is moving, so caching is not optional here.
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 64 }

    func icon(for url: URL?, fallbackSymbol: String) -> NSImage {
        if let url {
            let key = url.path as NSString
            if let cached = cache.object(forKey: key) { return cached }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            cache.setObject(icon, forKey: key)
            return icon
        }
        let symbol = NSImage(
            systemSymbolName: fallbackSymbol, accessibilityDescription: nil
        ) ?? NSImage()
        symbol.size = NSSize(width: 24, height: 24)
        return symbol
    }
}

struct AppIconView: View {
    let url: URL?
    var fallbackSymbol = "app.dashed"
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: url, fallbackSymbol: fallbackSymbol))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .opacity(url == nil ? 0.55 : 1)
    }
}

/// Stand-in for a site icon, drawn locally from the host name.
///
/// Audify deliberately never fetches favicons: doing so would mean the app making network requests
/// to every site the user visits, which is not a trade a volume mixer should make.
struct HostAvatar: View {
    let host: String
    var size: CGFloat = 24

    private var initial: String {
        String(host.first.map(String.init) ?? "•").uppercased()
    }

    private var color: Color {
        var hash: UInt64 = 5381
        for byte in host.utf8 { hash = (hash << 5) &+ hash &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.72)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

/// Volume slider covering 0–100%, or 0–200% when boost is enabled.
///
/// Custom rather than `Slider` because it needs three things AppKit's slider will not do: a unity
/// detent you can feel, a live level meter behind the track, and a boost region that is visually
/// distinct from normal range.
struct VolumeSlider: View {
    let value: Float
    let maxValue: Float
    var level: Float = 0
    var isMuted = false
    let onChange: (Float) -> Void
    var onCommit: () -> Void = {}

    private let trackHeight: CGFloat = 5
    private let knobSize: CGFloat = 13
    /// Snap window around 100%, in fraction-of-track units.
    private let detentWidth: Float = 0.02

    private var accent: Color {
        if isMuted { return .secondary }
        return value > 1.001 ? .orange : .accentColor
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = CGFloat(min(max(value, 0), maxValue) / maxValue)
            let fillWidth = width * fraction
            let unityX = maxValue > 1 ? width / CGFloat(maxValue) : width
            let meterWidth = width * CGFloat(min(level, maxValue) / maxValue)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: trackHeight)

                // Level meter sits inside the track, dimmed, so it reads as "signal" not "setting".
                if level > 0.005, !isMuted {
                    Capsule()
                        .fill(accent.opacity(0.28))
                        .frame(width: meterWidth, height: trackHeight)
                }

                Capsule()
                    .fill(accent.opacity(isMuted ? 0.35 : 0.95))
                    .frame(width: fillWidth, height: trackHeight)

                if maxValue > 1 {
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 1, height: 9)
                        .offset(x: unityX - 0.5)
                }

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: min(max(fillWidth - knobSize / 2, 0), width - knobSize))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        var next = Float(min(max(drag.location.x / width, 0), 1)) * maxValue
                        // Make 100% easy to land on exactly.
                        if maxValue > 1, abs(next - 1) < detentWidth * maxValue { next = 1 }
                        onChange(next)
                    }
                    .onEnded { _ in onCommit() }
            )
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step: Float = 0.05
            switch direction {
            case .increment: onChange(min(value + step, maxValue))
            case .decrement: onChange(max(value - step, 0))
            default: break
            }
            onCommit()
        }
    }
}

struct MuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .frame(width: 18, height: 18)
                .foregroundStyle(isMuted ? Color.red.opacity(0.9) : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute" : "Mute")
    }
}

/// Tappable percentage readout; clicking resets the row to 100%.
struct PercentLabel: View {
    let value: Float
    let isMuted: Bool
    let onReset: () -> Void

    var body: some View {
        Button(action: onReset) {
            Text(isMuted ? "—" : "\(Int((value * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value > 1.001 ? Color.orange : Color.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .help("Reset to 100%")
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}
