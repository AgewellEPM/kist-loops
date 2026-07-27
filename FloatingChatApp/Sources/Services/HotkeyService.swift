import Carbon
import Cocoa
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "Hotkey")

/// Service to register a global hotkey (Cmd+Shift+Space) that summons the app
final class HotkeyService {
    static let shared = HotkeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    // Callback when hotkey is pressed
    var onHotkeyPressed: (() -> Void)?

    private init() {}

    /// Register the global hotkey (Cmd+Shift+Space by default)
    func registerGlobalHotkey(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(cmdKey | shiftKey)) {
        // Unregister any existing hotkey first
        unregisterGlobalHotkey()

        // Create hotkey ID
        let hotKeyID = EventHotKeyID(signature: OSType(0x46434841), id: 1) // "FCHA"

        // Install event handler
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                HotkeyService.shared.handleHotkey()
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &eventHandler
        )

        if status != noErr {
            logger.error("Failed to install event handler: \(status)")
            return
        }

        // Register the hotkey
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            logger.error("Failed to register hotkey: \(registerStatus)")
        } else {
            logger.info("Global hotkey registered: Cmd+Shift+Space")
        }
    }

    /// Unregister the global hotkey
    func unregisterGlobalHotkey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            logger.info("Global hotkey unregistered")
        }

        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func handleHotkey() {
        logger.info("Hotkey pressed")
        DispatchQueue.main.async {
            self.onHotkeyPressed?()
        }
    }

    deinit {
        unregisterGlobalHotkey()
    }
}
