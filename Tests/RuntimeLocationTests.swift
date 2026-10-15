import Foundation

@main
struct RuntimeLocationTests {
    static func main() {
        let suite = "local.codex.notch.runtime-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = URL(fileURLWithPath: "/tmp/app-a/.codex-notch-runtime", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/app-b/.codex-notch-runtime", isDirectory: true)
        precondition(EventSpool.sharedDirectory(fallback: first, preferences: preferences) == first)
        precondition(preferences.dictionaryRepresentation()["CodexNotch.runtimeDirectory.v1"] == nil,
                     "Hook-style reads cannot register a different queue")
        EventSpool.rememberSharedDirectory(first, preferences: preferences)
        precondition(EventSpool.sharedDirectory(fallback: second, preferences: preferences) == first,
                     "A copied app must use the original queue after a complete restart")
        EventSpool.rememberSharedDirectory(second, preferences: preferences)
        precondition(EventSpool.sharedDirectory(fallback: second, preferences: preferences) == first,
                     "An app copy cannot replace a previously chosen runtime")
        let reconstructed = UserDefaults(suiteName: suite)!
        precondition(EventSpool.sharedDirectory(fallback: second, preferences: reconstructed) == first)
        for invalid in ["relative/.codex-notch-runtime", "/tmp/unrelated", "/tmp/a\0/.codex-notch-runtime", ""] {
            preferences.set(invalid, forKey: "CodexNotch.runtimeDirectory.v1")
            precondition(EventSpool.sharedDirectory(fallback: second, preferences: preferences) == second)
        }
        print("PASS: Shared runtime across copies, read-only hooks and preference validation (9 checks)")
    }
}
