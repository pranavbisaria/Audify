import AudifyKit
import Carbon.HIToolbox
import Foundation
import OSLog

/// A single system-wide keyboard shortcut, registered with the classic Carbon hot key API.
///
/// `RegisterEventHotKey` is the same mechanism Spotlight, the screenshot tool and countless
/// third-party menu bar apps use for global shortcuts. Two things make it the right tool here
/// rather than `NSEvent.addGlobalMonitorForEvents`: it needs no Accessibility or Input Monitoring
/// permission (Audify asks for nothing beyond audio capture), and it is a true OS-level key
/// registration rather than a stream of every keystroke on the system, so there is nothing running
/// on the hot path until the exact combination is pressed.
final class GlobalHotKey {
    private static let signature: OSType = 0x61756469 // 'audi'
    private static var nextID: UInt32 = 1
    /// Handlers keyed by the numeric hot key id, since the single Carbon event handler below is
    /// shared process-wide and has to dispatch back to the right Swift closure.
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installedEventHandler: EventHandlerRef?

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// Registers `action` to fire on every press of `keyCode`+`modifiers` while Audify is running.
    /// Returns `nil` if the combination could not be registered (already claimed by another app).
    init?(keyCode: UInt32, carbonModifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        id = Self.nextID
        Self.nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Logger(subsystem: AudifyLog.subsystem, category: "hotkey")
                .error("RegisterEventHotKey failed: \(status)")
            return nil
        }

        hotKeyRef = ref
        Self.handlers[id] = action
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.handlers.removeValue(forKey: id)
    }

    /// Installs the one process-wide Carbon event handler, lazily, on first use.
    private static func installHandlerIfNeeded() {
        guard installedEventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            guard let action = GlobalHotKey.handlers[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            // Hop back to the main run loop rather than doing UI/AudifyKit work directly inside
            // the Carbon callback.
            DispatchQueue.main.async(execute: action)
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType, nil, &installedEventHandler
        )
    }
}
