import Carbon.HIToolbox

/// Global ⌃⌥⌘T → `TrackerStore.toggle()`. Carbon's RegisterEventHotKey is still
/// the only public system-wide hot key API that needs no Accessibility permission.
@MainActor
enum HotKey {
    private static var hotKey: EventHotKeyRef?
    private static var handler: EventHandlerRef?

    /// Idempotent; called at launch and whenever `Prefs.hotKeyEnabled` may have changed.
    /// Returns why the shortcut could not be registered (Settings shows it), nil when it works or is off.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        guard enabled else {
            unregister()
            return nil
        }
        return register()
    }

    private static func register() -> String? {
        guard hotKey == nil else { return nil }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A C callback cannot capture anything; it only has one hot key to answer for.
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in await TrackerStore.shared.toggle() }
            return noErr
        }, 1, &pressed, nil, &handler)
        guard status == noErr else { return "⌃⌥⌘T could not be set up (error \(status))." }
        let id = EventHotKeyID(signature: OSType(0x4348_524E), id: 1) // "CHRN"
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey | cmdKey), id,
                                             GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            // Registration failed: leave nothing half-installed.
            unregister()
            return "⌃⌥⌘T is not available (error \(registered)); another app may use it."
        }
        return nil
    }

    private static func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
