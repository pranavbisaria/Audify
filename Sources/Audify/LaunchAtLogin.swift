import AppKit
import AudifyKit
import Foundation
import OSLog
import ServiceManagement

/// Wraps `SMAppService` so the UI can offer a single toggle.
///
/// `SMAppService.mainApp` is the modern, sandbox-friendly replacement for login item hacks: macOS
/// records the registration against the app's code signature, so it survives moves and updates and
/// shows up in System Settings ▸ General ▸ Login Items where users expect to find it.
@MainActor
final class LaunchAtLogin: ObservableObject {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)

        var isOn: Bool { self == .enabled || self == .requiresApproval }
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var lastError: String?

    private let log = Logger(subsystem: AudifyLog.subsystem, category: "login")

    init() { refresh() }

    func refresh() {
        guard Bundle.main.bundleIdentifier != nil else {
            state = .unavailable("Only available when running the packaged app.")
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            state = .enabled
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered, .notFound:
            state = .disabled
        @unknown default:
            state = .disabled
        }
    }

    func set(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The usual cause is an unsigned or ad-hoc-signed build; say so rather than failing mute.
            let message = (error as NSError).localizedDescription
            lastError = message
            log.error("Login item change failed: \(message, privacy: .public)")
        }
        refresh()
    }

    /// Opens the pane where a pending "requires approval" state is resolved.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var explanation: String? {
        switch state {
        case .requiresApproval:
            return "Approve Audify in System Settings ▸ General ▸ Login Items."
        case let .unavailable(reason):
            return reason
        default:
            return lastError
        }
    }
}
