import AppKit
import AudifyKit
import OSLog

// Audify is a menu bar utility: no Dock icon, no main window, nothing in the window menu.
// `main.swift` is used instead of `@main` + `App` so the activation policy is set before the
// first run loop turn, which stops a Dock icon from ever flashing on launch.

let rawArguments = Array(CommandLine.arguments.dropFirst())
let arguments = Set(rawArguments)

if let index = rawArguments.firstIndex(of: "--diagnose") {
    // An optional path lets the report be collected when Audify is opened by Launch Services.
    let outputPath = rawArguments.indices.contains(index + 1)
        && !rawArguments[index + 1].hasPrefix("--")
        ? rawArguments[index + 1] : nil
    Diagnostics.run(writingTo: outputPath)
    exit(0)
}

if arguments.contains("--version") {
    print("Audify \(AppInfo.version) (\(AppInfo.build))")
    exit(0)
}

let application = NSApplication.shared
let delegate = AudifyAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

final class AudifyAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private let log = Logger(subsystem: AudifyLog.subsystem, category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AudifyController()
        controller.start()
        menuBar = MenuBarController(controller: controller)
        log.info("Audify \(AppInfo.version, privacy: .public) launched")

        if !controller.preferences.hasCompletedSetup {
            controller.preferences.hasCompletedSetup = true
            // Surface the permission prompt and the menu immediately on a fresh install, so the
            // user is never left wondering whether anything happened.
            menuBar?.showWelcome()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.shutdown()
    }

    /// Clicking the app in Finder while it is already running should reveal the mixer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        menuBar?.togglePopover()
        return true
    }
}
