import AppKit
import Carbon

@main
struct KeyboardTests {
    private static var checks = 0

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        try expect(GlobalShortcut.standard.isValid, "Default shortcut is valid")
        try expect(GlobalShortcut.standard.title == "⌃⌥Пробел", "Default shortcut is readable")
        let plain = GlobalShortcut(keyCode: 0, modifiers: 0, keyLabel: "A")
        let shift = GlobalShortcut(keyCode: 0, modifiers: UInt32(shiftKey), keyLabel: "A")
        try expect(!plain.isValid && !shift.isValid, "Typing shortcuts cannot replace ordinary typing")
        try expect(!GlobalShortcut(keyCode: 128, modifiers: UInt32(cmdKey), keyLabel: "A").isValid,
                   "Invalid hardware key codes are rejected")
        try expect(!GlobalShortcut(keyCode: 0, modifiers: UInt32(cmdKey), keyLabel: "\n").isValid,
                   "Control characters never appear in labels")
        try expect(!GlobalShortcut(keyCode: 0, modifiers: UInt32(cmdKey) | 0x80000000, keyLabel: "A").isValid,
                   "Unknown modifier bits are rejected")
        let commandA = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0)!
        try expect(GlobalShortcut.captured(from: commandA)?.title == "⌘A", "Explicit sheet captures a readable modified key")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: UInt16(kVK_Escape))!
        try expect(GlobalShortcut.captured(from: escape) == nil, "Escape remains available to cancel the sheet")
        let suite = "local.codex.notch.keyboard-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "CodexNotch.dashboardShortcut.disabled")
        let shortcut = GlobalShortcut(keyCode: UInt32(kVK_F19),
            modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), keyLabel: "F19")
        do {
            let controller = GlobalShortcutController(defaults: preferences, action: {})
            try expect(!controller.isEnabled, "Disabled preference is respected before registration")
            try expect(controller.configure(shortcut), "System registers a deliberate custom combination")
            try expect(controller.isEnabled && controller.error == nil, "Successful registration has no error")
            try expect(controller.configure(shortcut), "Reapplying the same combination does not report a conflict")
            let otherSuite = suite + ".collision"
            let otherPreferences = UserDefaults(suiteName: otherSuite)!
            defer { otherPreferences.removePersistentDomain(forName: otherSuite) }
            otherPreferences.set(true, forKey: "CodexNotch.dashboardShortcut.disabled")
            let other = GlobalShortcutController(defaults: otherPreferences, action: {})
            try expect(!other.configure(shortcut), "An occupied global combination is reported instead of silently stolen")
            try expect(!other.isEnabled && other.error != nil, "A conflict leaves the other controller disabled")
            try expect(controller.configure(nil), "Shortcut can be disabled")
            try expect(!controller.isEnabled, "Disable updates state immediately")
        }
        let restored = GlobalShortcutController(defaults: preferences, action: {})
        try expect(restored.shortcut == shortcut && !restored.isEnabled, "Custom shortcut and disabled state survive reconstruction")
        try expect(restored.configure(shortcut), "Disabled custom shortcut can be enabled again")
        _ = restored.configure(nil)
        print("PASS: Keyboard (\(checks) checks)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(message: message) }
    }
    private struct Failure: Error { let message: String }
}
