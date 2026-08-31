import AppKit
import AudifyKit
import Combine
import SwiftUI

/// Owns the menu bar item, the mixer popover and the settings window.
///
/// The popover is created lazily and its SwiftUI view is only observing anything while it is
/// visible, which is what lets Audify sit at effectively zero CPU when the user is not looking at it.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let controller: AudifyController
    private let launchAtLogin = LaunchAtLogin()
    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    init(controller: AudifyController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        // Keep the glyph in step with mute state without observing anything expensive.
        controller.output.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatusImage() }
            }
            .store(in: &cancellables)
        updateStatusImage()
    }

    // MARK: - Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Audify — per-app volume"
        button.setAccessibilityLabel("Audify volume mixer")
    }

    private func updateStatusImage() {
        guard let button = statusItem.button else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(
            systemSymbolName: controller.statusSymbol,
            accessibilityDescription: "Audify"
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
    }

    @objc private func handleClick() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - Popover

    func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        let popover = popover ?? makePopover()
        self.popover = popover
        controller.setUIVisible(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Bring the popover forward without stealing focus from the user's frontmost app more
        // than necessary.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let view = MixerView(
            controller: controller,
            preferences: controller.preferences,
            output: controller.output,
            bridge: controller.bridge,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        return popover
    }

    func popoverDidClose(_ notification: Notification) {
        controller.setUIVisible(false)
    }

    // MARK: - Context menu

    private func showContextMenu() {
        let menu = NSMenu()

        let mute = NSMenuItem(
            title: controller.output.isMuted ? "Unmute Output" : "Mute Output",
            action: #selector(toggleMasterMute), keyEquivalent: ""
        )
        mute.target = self
        menu.addItem(mute)

        if controller.hasAnyAdjustment {
            let reset = NSMenuItem(
                title: "Reset All Levels", action: #selector(resetAll), keyEquivalent: ""
            )
            reset.target = self
            menu.addItem(reset)
        }

        menu.addItem(.separator())

        let mixer = NSMenuItem(title: "Open Mixer", action: #selector(openMixer), keyEquivalent: "")
        mixer.target = self
        menu.addItem(mixer)

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Audify", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // A status item keeps showing its menu on left click until the menu is detached again.
        statusItem.menu = nil
    }

    @objc private func toggleMasterMute() { controller.toggleMasterMute() }
    @objc private func resetAll() { controller.resetAll() }
    @objc private func openMixer() { showPopover() }
    @objc private func openSettings() { showSettings() }

    // MARK: - Settings

    func showSettings() {
        popover?.performClose(nil)

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = SettingsView(
            controller: controller,
            preferences: controller.preferences,
            bridge: controller.bridge,
            launchAtLogin: launchAtLogin
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Audify Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = windowDelegate
        settingsWindow = window

        launchAtLogin.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private lazy var windowDelegate = SettingsWindowDelegate { [weak self] in
        self?.settingsWindow = nil
    }

    // MARK: - Welcome

    /// First launch: open the mixer so the app is obviously alive, and ask about starting at login.
    func showWelcome() {
        controller.refreshPermission()
        showPopover()
        // Asked rather than assumed. Registering a login item silently is the kind of thing that
        // makes people distrust menu bar apps.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            self.askAboutLaunchAtLogin()
        }
    }

    private func askAboutLaunchAtLogin() {
        guard launchAtLogin.state == .disabled else { return }

        let alert = NSAlert()
        alert.messageText = "Start Audify when you log in?"
        alert.informativeText = """
        Audify lives in the menu bar and does nothing until you adjust an app, so leaving it on         costs no battery. You can change this any time in Settings.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start at Login")
        alert.addButton(withTitle: "Not Now")
        alert.icon = NSApp.applicationIconImage

        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            launchAtLogin.set(true)
            if let explanation = launchAtLogin.explanation, launchAtLogin.state != .enabled {
                let followUp = NSAlert()
                followUp.messageText = "One more step"
                followUp.informativeText = explanation
                followUp.addButton(withTitle: "Open Login Items")
                followUp.addButton(withTitle: "Later")
                if followUp.runModal() == .alertFirstButtonReturn {
                    launchAtLogin.openLoginItemsSettings()
                }
            }
        }
    }

    func shutdown() {
        controller.stop()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
