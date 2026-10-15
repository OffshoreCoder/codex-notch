import Foundation
import IOKit.pwr_mgt

/// Opt-in smoke test of this process's own short-lived public IOKit assertions.
/// No pmset, display activity assertion, sleep/wake action, or stored preference.
@main
struct KeepAwakeNativeTests {
    private static var checks = 0

    static func main() throws {
        guard CommandLine.arguments.contains("--run-native-smoke") else {
            print("SKIP: KeepAwake native smoke (opt in with --run-native-smoke)")
            return
        }
        let client = NativeKeepAwakeAssertionClient()
        try explicitRelease(client)
        try automaticRelease(client)
        print("PASS: KeepAwake native smoke (\(checks) checks; temporary assertions released; sleep settings unchanged)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(message: message) }
    }

    private static func create(_ client: NativeKeepAwakeAssertionClient, timeout: TimeInterval) throws -> UInt32 {
        switch client.create(timeout: timeout) {
        case .success(let id): return id
        case .failure(let error): throw Failure(message: "Native assertion creation failed: " + error.message)
        }
    }

    private static func properties(_ id: UInt32) -> [String: Any]? {
        guard let copied = IOPMAssertionCopyProperties(id)?.takeRetainedValue() else { return nil }
        return copied as NSDictionary as? [String: Any]
    }

    private static func explicitRelease(_ client: NativeKeepAwakeAssertionClient) throws {
        let id = try create(client, timeout: 4)
        var released = false
        defer { if !released { _ = client.release(id) } }
        try expect(id != 0, "Public API returns a nonzero own assertion ID")
        guard let own = properties(id) else { throw Failure(message: "Own assertion properties unavailable") }
        try expect(own[kIOPMAssertionTypeKey as String] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep,
                   "Only automatic system sleep is prevented; display sleep remains allowed")
        try expect((own[kIOPMAssertionLevelKey as String] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn),
                   "The native assertion is active")
        let timeout = (own[kIOPMAssertionTimeoutKey as String] as? NSNumber)?.doubleValue ?? 0
        try expect(timeout > 0 && timeout <= 4, "Native timeout is bounded to at most four seconds")
        try expect(own[kIOPMAssertionTimeoutActionKey as String] as? String == kIOPMAssertionTimeoutActionRelease,
                   "A stalled process cannot leave this assertion enabled after timeout")
        try expect(own[kIOPMAssertionNameKey as String] as? String == "Codex Notch: active turns",
                   "System-visible assertion name contains no chat names or paths")
        try expect(client.release(id) == kIOReturnSuccess, "Public explicit release succeeds")
        released = true
        try expect(waitForRelease(id, deadline: ProcessInfo.processInfo.systemUptime + 1),
                   "Explicit release removes this process's assertion")
    }

    private static func automaticRelease(_ client: NativeKeepAwakeAssertionClient) throws {
        let id = try create(client, timeout: 1)
        defer { if properties(id) != nil { _ = client.release(id) } }
        try expect(properties(id) != nil, "Short automatic-release assertion exists before timeout")
        try expect(waitForRelease(id, deadline: ProcessInfo.processInfo.systemUptime + 4),
                   "macOS automatically releases the assertion without another app heartbeat")
    }

    private static func waitForRelease(_ id: UInt32, deadline: TimeInterval) -> Bool {
        repeat {
            if properties(id) == nil { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return properties(id) == nil
    }

    private struct Failure: Error { let message: String }
}
