import AppKit
import Carbon

/// A registered system shortcut, never a global keyboard event tap or monitor.
struct GlobalShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let standard = GlobalShortcut(keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey), keyLabel: "Пробел")
    static let alternate = GlobalShortcut(keyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey | shiftKey), keyLabel: "Пробел")
    static let allowedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)

    var isValid: Bool {
        keyCode <= 127 && modifiers & ~Self.allowedModifiers == 0 &&
            modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 &&
            !keyLabel.isEmpty && keyLabel.count <= 16 &&
            !keyLabel.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    var title: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    static func captured(from event: NSEvent) -> GlobalShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        // Capture only a deliberate combination; Escape and Return keep their modal meaning.
        let reserved: [UInt16] = [UInt16(kVK_Escape), UInt16(kVK_Return), UInt16(kVK_Tab),
            UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)]
        guard !reserved.contains(event.keyCode) else { return nil }
        let special: [UInt16: String] = [UInt16(kVK_Space): "Пробел", UInt16(kVK_LeftArrow): "←",
            UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓"]
        let functionCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                             kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                             kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let functionLabel = functionCodes.firstIndex(of: Int(event.keyCode)).map { "F\($0 + 1)" }
        let label = special[event.keyCode] ?? functionLabel ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let shortcut = GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        return shortcut.isValid ? shortcut : nil
    }
}

@MainActor
final class GlobalShortcutController {
    private let defaults: UserDefaults
    private let storageKey = "CodexNotch.dashboardShortcut.v1"
    private let disabledKey = "CodexNotch.dashboardShortcut.disabled"
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void
    private(set) var shortcut: GlobalShortcut
    private(set) var isEnabled: Bool
    private(set) var error: String?
    private let signature: OSType = 0x434E5448 // CNTH

    init(defaults: UserDefaults = .standard, action: @escaping () -> Void) {
        self.defaults = defaults
        self.action = action
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data), saved.isValid {
            shortcut = saved
        } else { shortcut = .standard }
        isEnabled = !defaults.bool(forKey: disabledKey)
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x434E5448, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcutController>.fromOpaque(context).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status != noErr { error = "Не удалось подключить системное сочетание (\(status))." }
        else if isEnabled { register() }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    var statusTitle: String {
        if let error { return error }
        return isEnabled ? "Открыть пульт: \(shortcut.title)" : "Горячая клавиша выключена"
    }

    /// Keep the old usable shortcut when the new one is reserved by another app.
    @discardableResult
    func configure(_ value: GlobalShortcut?) -> Bool {
        guard let value else {
            if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
            isEnabled = false
            error = nil
            defaults.set(true, forKey: disabledKey)
            return true
        }
        guard value.isValid, eventHandler != nil else { return false }
        if value == shortcut, hotKey != nil { error = nil; return true }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(value.keyCode, value.modifiers,
            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else {
            error = "Сочетание \(value.title) занято или недоступно. Выбери другое."
            return false
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        shortcut = value
        isEnabled = true
        error = nil
        defaults.set(false, forKey: disabledKey)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: storageKey) }
        return true
    }

    private func register() {
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { error = "Сочетание \(shortcut.title) занято или недоступно. Выбери другое." }
    }
}
