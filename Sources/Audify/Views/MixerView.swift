import AudifyKit
import SwiftUI

/// The popover: master output at the top, then every app making sound, then browser tabs.
struct MixerView: View {
    @ObservedObject var controller: AudifyController
    @ObservedObject var preferences: Preferences
    @ObservedObject var output: OutputDeviceController
    @ObservedObject var bridge: BridgeServer

    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    /// Keeps the popover from growing past a sensible height; the list scrolls beyond this.
    private let maxListHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            masterSection
            Divider()

            if controller.permission == .denied {
                permissionBanner
            } else if let message = controller.engineMessage {
                warningBanner(message)
            }

            ScrollView {
                VStack(spacing: 0) {
                    appsSection
                    tabsSection
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: maxListHeight)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.statusSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Audify")
                    .font(.system(size: 13, weight: .semibold))
                Text(controller.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.hasAnyAdjustment {
                Button("Reset", action: controller.resetAll)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Return every app and site to 100%")
            }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Master

    private var masterSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(output.devices) { device in
                        Button {
                            output.selectDevice(device)
                        } label: {
                            Label(device.name, systemImage: device.symbolName)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: currentDeviceSymbol)
                            .font(.system(size: 10))
                        Text(output.defaultDeviceName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose the output device")

                Spacer(minLength: 0)

                if !output.supportsVolumeControl {
                    Text("no software volume")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 8) {
                MuteButton(isMuted: output.isMuted) {
                    controller.toggleMasterMute()
                }
                VolumeSlider(
                    value: output.masterVolume,
                    maxValue: 1,
                    isMuted: output.isMuted,
                    onChange: { controller.setMasterVolume($0) }
                )
                .disabled(!output.supportsVolumeControl)
                .opacity(output.supportsVolumeControl ? 1 : 0.4)

                PercentLabel(value: output.masterVolume, isMuted: output.isMuted) {
                    controller.setMasterVolume(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var currentDeviceSymbol: String {
        output.devices.first { $0.id == output.defaultDeviceID }?.symbolName ?? "speaker.wave.2"
    }

    // MARK: - Apps

    private var appsSection: some View {
        Group {
            SectionHeader(
                title: "Apps",
                trailing: controller.appRows.isEmpty ? nil : "\(controller.appRows.count)"
            )

            if controller.appRows.isEmpty {
                EmptyRow(
                    symbol: "speaker.slash",
                    title: "Nothing is playing",
                    detail: "Apps appear here as soon as they use audio."
                )
            } else {
                ForEach(controller.appRows) { row in
                    AppRowView(
                        row: row,
                        maxGain: preferences.maxGain,
                        showMeter: preferences.showMeters,
                        onVolume: { controller.setVolume($0, forApp: row.id) },
                        onMute: { controller.toggleMute(app: row.id) },
                        onReset: { controller.resetApp(row.id) },
                        onSolo: { controller.solo(app: row.id) }
                    )
                }
            }
        }
    }

    // MARK: - Tabs

    private var tabsSection: some View {
        Group {
            SectionHeader(title: "Browser Tabs", trailing: bridgeStatusText)

            if !preferences.bridgeEnabled {
                EmptyRow(
                    symbol: "puzzlepiece.extension",
                    title: "Tab control is off",
                    detail: "Turn it on in Settings to control individual tabs."
                )
            } else if controller.tabRows.isEmpty {
                EmptyRow(
                    symbol: bridge.isConnected ? "macwindow.on.rectangle" : "puzzlepiece.extension",
                    title: bridge.isConnected ? "No audible tabs" : "Browser extension not connected",
                    detail: bridge.isConnected
                        ? "Play something in a tab and it shows up here."
                        : "Install the Audify extension, then paste the pairing code from Settings."
                )
            } else {
                ForEach(controller.tabRows) { row in
                    TabRowView(
                        row: row,
                        maxGain: preferences.maxGain,
                        onVolume: { controller.setVolume($0, forTab: row) },
                        onMute: { controller.toggleMute(tab: row) },
                        onReset: { controller.setVolume(1, forTab: row) }
                    )
                }
            }
        }
    }

    private var bridgeStatusText: String? {
        guard preferences.bridgeEnabled else { return nil }
        let browsers = bridge.clients.filter(\.isAuthenticated).map(\.browserName)
        if browsers.isEmpty { return "not connected" }
        return browsers.joined(separator: ", ")
    }

    // MARK: - Banners

    private var permissionBanner: some View {
        Banner(
            symbol: "waveform.badge.exclamationmark",
            tint: .orange,
            title: "Audify needs permission to mix audio",
            detail: "macOS is handing Audify silent audio. Switch Audify on under Privacy & Security ▸ Audio Recording, then quit and reopen Audify. Nothing is ever recorded or saved.",
            actionTitle: "Open Settings",
            action: controller.openPermissionSettings,
            secondaryTitle: "Recheck",
            secondaryAction: controller.refreshPermission
        )
    }

    private func warningBanner(_ message: String) -> some View {
        Banner(
            symbol: "exclamationmark.triangle",
            tint: .yellow,
            title: "Audio engine problem",
            detail: message,
            actionTitle: "Recheck",
            action: controller.refreshPermission,
            secondaryTitle: nil,
            secondaryAction: nil
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Audify \(AppInfo.version)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit", action: onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - Rows

struct AppRowView: View {
    let row: AppRow
    let maxGain: Float
    let showMeter: Bool
    let onVolume: (Float) -> Void
    let onMute: () -> Void
    let onReset: () -> Void
    let onSolo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(url: row.bundleURL, fallbackSymbol: "app.dashed")
                .overlay(alignment: .bottomTrailing) {
                    if row.isPlaying {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(.background, lineWidth: 1))
                            .offset(x: 1, y: 1)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if row.isBrowser {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .help("Individual tabs can be controlled below")
                    }
                }
                HStack(spacing: 8) {
                    MuteButton(isMuted: row.muted, action: onMute)
                    VolumeSlider(
                        value: row.volume,
                        maxValue: maxGain,
                        level: showMeter ? row.level : 0,
                        isMuted: row.muted,
                        onChange: onVolume
                    )
                    PercentLabel(value: row.volume, isMuted: row.muted, onReset: onReset)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contextMenu {
            Button("Reset to 100%", action: onReset)
            Button(row.muted ? "Unmute" : "Mute", action: onMute)
            Divider()
            Button("Mute everything else", action: onSolo)
        }
    }
}

struct TabRowView: View {
    let row: TabRow
    let maxGain: Float
    let onVolume: (Float) -> Void
    let onMute: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HostAvatar(host: row.host)
                .overlay(alignment: .bottomTrailing) {
                    if row.audible {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(.background, lineWidth: 1))
                            .offset(x: 1, y: 1)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    MuteButton(isMuted: row.muted, action: onMute)
                    VolumeSlider(
                        value: row.volume, maxValue: maxGain, isMuted: row.muted, onChange: onVolume
                    )
                    PercentLabel(value: row.volume, isMuted: row.muted, onReset: onReset)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .help("\(row.host) — \(row.browserName)")
        .contextMenu {
            Button("Reset to 100%", action: onReset)
            Button(row.muted ? "Unmute" : "Mute", action: onMute)
        }
    }
}

// MARK: - Small pieces

struct EmptyRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .controlSize(.small)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.08))
    }
}
