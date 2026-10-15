import Foundation

@main
struct PrivacyTests {
    private static var checks = 0
    private static let a = "00112233-4455-6677-8899-aabbccddeeff"
    private static let b = "ffeeddcc-bbaa-9988-7766-554433221100"
    private static let c = "aabbccdd-1122-3344-5566-77889900aabb"

    static func main() throws {
        var privacy = PrivacyPresentation(orderedSessionIDs: [a, b, a.uppercased(), "private-id-sentinel"])
        try expect(privacy.name(for: a, original: "Private feature", isSharing: true) == "Задача 1", "First known task gets a generic ordinal")
        try expect(privacy.name(for: b, original: "Private branch", isSharing: true) == "Задача 2", "Distinct task gets its own ordinal")
        try expect(privacy.name(for: a.uppercased(), original: "Private feature", isSharing: true) == "Задача 1", "UUID case does not change the generic label")
        try expect(privacy.name(for: c, original: "private-name-sentinel", isSharing: true) == "Задача", "Unknown task has a generic fallback that exposes neither name nor ID")
        try expect(privacy.name(for: "private-id-sentinel", original: "private-name-sentinel", isSharing: true) == "Задача", "Malformed ID is never used as visible fallback")
        try expect(privacy.name(for: a, original: "Private feature", isSharing: false) == "Private feature", "Leaving presentation mode restores the original name")
        privacy.observe(sessionIDs: [b])
        try expect(privacy.name(for: b, original: "Private branch", isSharing: true) == "Задача 2", "Filtering or reordering must not renumber tasks")
        privacy.observe(sessionIDs: [c, a, b])
        try expect(privacy.name(for: c, original: "Private result", isSharing: true) == "Задача 3", "A new observed chat gets the next label")
        try expect(privacy.name(for: a, original: "Private feature", isSharing: true) == "Задача 1", "Adding chats must not move existing labels")
        try expect(privacy.context("backend · fix/private · /Users/private/work", isSharing: true) == nil, "Project, branch, and path context is hidden")
        try expect(privacy.context("backend · fix/cache", isSharing: false) == "backend · fix/cache", "Ordinary mode preserves project context")
        try expect(privacy.context(nil, isSharing: true) == nil, "Missing context remains absent")
        try expect(privacy.diagnostic("Cannot read /Users/private/secret.json", isSharing: true) == PrivacyPresentation.genericDiagnostic, "Diagnostics must not expose a local path")
        try expect(privacy.diagnostic("Original error", isSharing: false) == "Original error", "Original error remains available outside presentation mode")
        try expect(privacy.notice("Private feature is ready", isSharing: true) == PrivacyPresentation.genericNotice, "Arbitrary notice text must be masked")
        try expect(privacy.notice("Private feature is ready", isSharing: false) == "Private feature is ready", "Normal notice copy remains intact")
        let ids = (0..<600).map { String(format: "00000000-0000-0000-0000-%012x", $0) }
        let bounded = PrivacyPresentation(orderedSessionIDs: ids)
        try expect(bounded.name(for: ids[511], original: "Private", isSharing: true) == "Задача 512", "Bounded ordinal storage includes the last supported chat")
        try expect(bounded.name(for: ids[512], original: "Private", isSharing: true) == "Задача", "Overflow uses safe generic fallback")
        print("PASS: PrivacyPresentation (\(checks) checks)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(message: message) }
    }

    private struct Failure: Error { let message: String }
}
