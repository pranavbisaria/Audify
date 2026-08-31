import AppKit
import AudifyKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AudifyController
    @ObservedObject var preferences: Preferences
    @ObservedObject var bridge: BridgeServer
    @ObservedObject var launchAtLogin: LaunchAtLogin

    @State private var copiedCode = false
    @State private var portText = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            browserTab
                .tabItem { Label("Browser", systemImage: "safari") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 440, height: 400)
        .onAppear { portText = String(preferences.bridgePort) }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch Audify at login", isOn: launchAtLoginBinding)
                if let explanation = launchAtLogin.explanation {
                    HStack(spacing: 6) {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if launchAtLogin.state == .requiresApproval {
                            Button("Open Login Items") {
                                launchAtLogin.openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("Mixer") {
                Toggle("Allow volume boost above 100%", isOn: $preferences.allowBoost)
                Text("Adds headroom up to 200% with a soft limiter, for quiet sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show level meters", isOn: $preferences.showMeters)
                Toggle("Hide apps that are not playing", isOn: $preferences.hideIdleApps)
            }

            Section("Permission") {
                HStack(spacing: 8) {
                    Image(systemName: permissionSymbol)
                        .foregroundStyle(permissionColor)
                    Text(permissionText)
                        .font(.callout)
                    Spacer()
                    if controller.permission != .granted {
                        Button("Open Settings", action: controller.openPermissionSettings)
                            .controlSize(.small)
                    }
                    Button("Recheck", action: controller.refreshPermission)
                        .controlSize(.small)
                }
                Text("Audify uses macOS audio taps to change an app's level. Audio is never written to disk or sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.state.isOn },
            set: { launchAtLogin.set($0) }
        )
    }

    private var permissionSymbol: String {
        switch controller.permission {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var permissionColor: Color {
        switch controller.permission {
        case .granted: return .green
        case .denied: return .orange
        case .unknown: return .secondary
        }
    }

    private var permissionText: String {
        switch controller.permission {
        case .granted: return "Audio mixing is working"
        case .denied: return "Blocked — macOS is delivering silence"
        case .unknown: return "Not confirmed yet — adjust an app that is playing"
        }
    }

    // MARK: - Browser

    private var browserTab: some View {
        Form {
            Section {
                Toggle("Control individual browser tabs", isOn: $preferences.bridgeEnabled)
                    .onChange(of: preferences.bridgeEnabled) { _, _ in controller.restartBridge() }
                Toggle("Remember each site's level", isOn: $preferences.rememberPerSite)
                Text("A site you turn down stays down the next time you open it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(bridgeColor)
                        .frame(width: 8, height: 8)
                    Text(bridgeStatusText)
                        .font(.callout)
                    Spacer()
                }

                LabeledContent("Pairing code") {
                    HStack(spacing: 6) {
                        Text(preferences.bridgeToken)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copiedCode ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                preferences.bridgeToken, forType: .string
                            )
                            copiedCode = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedCode = false
                            }
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("Port") {
                    HStack(spacing: 6) {
                        TextField("", text: $portText)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Button("Apply") {
                            if let port = Int(portText), (1024...65535).contains(port) {
                                preferences.bridgePort = port
                                controller.restartBridge()
                            } else {
                                portText = String(preferences.bridgePort)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Extension") {
                Text("Load the extension from the Audify app bundle, then paste the pairing code into its popup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reveal Extension Folder") { revealExtension() }
                        .controlSize(.small)
                    Button("Setup Instructions") { openInstructions() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var bridgeColor: Color {
        switch bridge.state {
        case .listening: return bridge.isConnected ? .green : .yellow
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var bridgeStatusText: String {
        switch bridge.state {
        case .stopped:
            return "Off"
        case let .failed(reason):
            return "Failed — \(reason)"
        case let .listening(port):
            let paired = bridge.clients.filter(\.isAuthenticated)
            if paired.isEmpty {
                return "Waiting for a browser on 127.0.0.1:\(port)"
            }
            return "Connected to " + paired.map(\.browserName).joined(separator: ", ")
        }
    }

    private func revealExtension() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Extension"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Extension"),
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            return
        }
        NSWorkspace.shared.selectFile(
            Bundle.main.bundleURL.path,
            inFileViewerRootedAtPath: Bundle.main.bundleURL.deletingLastPathComponent().path
        )
    }

    private func openInstructions() {
        guard let url = Bundle.main.url(forResource: "BROWSER-SETUP", withExtension: "md")
            ?? Bundle.main.resourceURL?
                .appendingPathComponent("Extension/README.md")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        Form {
            Section("Latency") {
                Picker("Audio buffer", selection: $preferences.latency) {
                    ForEach(LatencyProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(preferences.latency.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Only affects apps whose volume is not 100%. Everything else is untouched by Audify and has no added delay at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Engine") {
                let diagnostics = controller.engine.diagnostics()
                LabeledContent("Status", value: diagnostics.isRunning ? "Running" : "Idle")
                LabeledContent("Apps being processed", value: "\(diagnostics.tapCount)")
                LabeledContent("Dropped buffers", value: "\(diagnostics.skippedCycles)")
                Text(diagnostics.tapCount == 0
                    ? "Idle: no audio graph exists, so Audify is using no CPU on audio at all."
                    : "One aggregate device and one render callback handle every adjusted app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset every app and site to 100%", action: controller.resetAll)
                Button("Run Diagnostics in Terminal") { runDiagnostics() }
            }

            Section {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
        }
        .formStyle(.grouped)
    }

    private func runDiagnostics() {
        let executable = Bundle.main.executableURL?.path ?? "Audify"
        let script = """
        tell application "Terminal"
            activate
            do script "\(executable.replacingOccurrences(of: "\"", with: "\\\"")) --diagnose"
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        appleScript.executeAndReturnError(nil)
    }
}
