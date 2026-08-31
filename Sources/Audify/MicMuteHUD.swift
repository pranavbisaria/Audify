import AppKit

/// The on-screen confirmation shown when the microphone is toggled from the global shortcut.
///
/// Modelled on the system volume/brightness HUD: a small borderless panel, centred near the top of
/// the screen, that fades itself out. It is built and torn down on demand — there is no window,
/// timer or view hierarchy alive between toggles, so this costs nothing until the shortcut is
/// actually pressed.
@MainActor
enum MicMuteHUD {
    private static var panel: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    static func show(muted: Bool) {
        dismissWorkItem?.cancel()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        configure(panel, muted: muted)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { dismiss() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: workItem)
    }

    private static func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private static func makePanel() -> NSPanel {
        let size = NSSize(width: 120, height: 120)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true

        let imageView = NSImageView(frame: NSRect(x: 30, y: 42, width: 60, height: 60))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.symbolConfiguration = .init(pointSize: 40, weight: .medium)
        imageView.identifier = NSUserInterfaceItemIdentifier("icon")

        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 0, y: 14, width: size.width, height: 18)
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.identifier = NSUserInterfaceItemIdentifier("label")

        background.addSubview(imageView)
        background.addSubview(label)
        panel.contentView = background
        return panel
    }

    private static func configure(_ panel: NSPanel, muted: Bool) {
        guard let background = panel.contentView,
              let imageView = background.subviews.first(where: {
                  $0.identifier?.rawValue == "icon"
              }) as? NSImageView,
              let label = background.subviews.first(where: {
                  $0.identifier?.rawValue == "label"
              }) as? NSTextField
        else { return }

        let symbol = muted ? "mic.slash.fill" : "mic.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.image = image
        imageView.contentTintColor = muted ? .systemRed : .labelColor
        label.stringValue = muted ? "Mic Muted" : "Mic On"

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - panel.frame.height - 90
            )
            panel.setFrameOrigin(origin)
        }
    }
}
