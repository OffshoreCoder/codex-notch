import Foundation

@main
struct KeepAwakeTests {
    private static var checks = 0
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() throws {
        try eligibility()
        try lifecycle()
        try renewalAndFailures()
        try termination()
        try persistence()
        print("PASS: KeepAwake (\(checks) checks; native sleep settings unchanged)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(message: message) }
    }

    private static func chat(_ id: String = "chat", state: CompanionState = .working,
                             turn: String? = "turn", started: Date? = now.addingTimeInterval(-60),
                             updated: Date = now, ended: Date? = nil) -> ChatSummary {
        ChatSummary(id: id, turnID: turn, state: state, startedAt: started,
                    updatedAt: updated, endedAt: ended)
    }

    private static func eligible(_ chats: [ChatSummary], enabled: Bool = true, preview: Bool = false,
                                 blocked: Set<String> = []) -> Set<String> {
        KeepAwakePolicy.eligibleSessionIDs(enabled: enabled, isPreview: preview,
            liveChats: chats, blockedSessionIDs: blocked, now: now)
    }

    private static func eligibility() throws {
        try expect(eligible([chat()], enabled: false).isEmpty, "Preference is off by default")
        try expect(eligible([chat()], preview: true).isEmpty, "Preview must never prevent sleep")
        try expect(eligible([]).isEmpty, "No live turn means no assertion")
        for state in [CompanionState.working, .coding, .checking] {
            try expect(eligible([chat(state: state)]) == ["chat"], "Fresh active lifecycle is eligible: \(state)")
        }
        for state in [CompanionState.idle, .finished, .interrupted, .unknown, .needsAnswer, .needsReview] {
            try expect(eligible([chat(state: state)]).isEmpty, "Inactive or waiting lifecycle is excluded: \(state)")
        }
        try expect(eligible([chat()], blocked: ["chat"]).isEmpty, "An explicit question blocks an otherwise active turn")
        try expect(eligible([chat("one"), chat("two")], blocked: ["one"]) == ["two"], "A waiting chat must not stop other useful work")
        try expect(eligible([chat(), chat()]).count == 1, "Duplicate cards cannot inflate active count")
        try expect(eligible([chat(turn: nil)]).isEmpty, "Orphan tool event without known root lifecycle is excluded")
        try expect(eligible([chat(turn: "")]).isEmpty, "Empty turn is not evidence of active work")
        try expect(eligible([chat(started: nil)]).isEmpty, "No known turn start is excluded")
        try expect(eligible([chat(ended: now)]).isEmpty, "An ended turn cannot be reactivated")
        try expect(eligible([chat(started: now.addingTimeInterval(1))]).isEmpty, "Future start is excluded")
        try expect(eligible([chat(updated: now.addingTimeInterval(1))]).isEmpty, "Future event is excluded")
        try expect(eligible([chat(started: now, updated: now.addingTimeInterval(-1))]).isEmpty, "Invalid metadata ordering is excluded")
        try expect(eligible([chat(started: now.addingTimeInterval(-3600), updated: now.addingTimeInterval(-KeepAwakePolicy.maximumEventAge))]).isEmpty, "Stale threshold is exclusive")
        try expect(eligible([chat(started: now.addingTimeInterval(-3600), updated: now.addingTimeInterval(-KeepAwakePolicy.maximumEventAge + 1))]) == ["chat"], "Live model freshness has consistent bounds")
        try expect(eligible([chat(updated: Date(timeIntervalSince1970: .nan))]).isEmpty, "Non-finite timestamps cannot create assertions")
        try expect(eligible([chat("")]).isEmpty, "Empty session ID is excluded")
    }

    private static func lifecycle() throws {
        let fake = FakeClient()
        let controller = KeepAwakeController(client: fake)
        try expect(controller.status == .off && controller.assertionID == nil, "Controller does not acquire on construction")
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 10)
        try expect(controller.status == .active && controller.activeChatCount == 1, "Enabled active turn acquires assertion")
        try expect(controller.assertionID == 1 && fake.creates == [120], "Native assertion is a bounded two-minute lease")
        controller.update(enabled: true, isPreview: false, liveChats: [chat("one"), chat("two")], now: now, uptime: 11)
        try expect(controller.activeChatCount == 2 && fake.creates.count == 1, "Parallel chats reuse one assertion")
        controller.update(enabled: true, isPreview: false, liveChats: [chat(state: .finished)], now: now, uptime: 12)
        try expect(controller.status == .waiting && controller.assertionID == nil && fake.released == [1], "Stop releases immediately")
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 13)
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], blockedSessionIDs: ["chat"], now: now, uptime: 14)
        try expect(controller.status == .waiting && fake.released == [1, 2], "Explicit question releases immediately")
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 15)
        controller.update(enabled: false, isPreview: false, liveChats: [chat()], now: now, uptime: 16)
        try expect(controller.status == .off && fake.released == [1, 2, 3], "Toggle off releases immediately")
        controller.update(enabled: true, isPreview: true, liveChats: [chat()], now: now, uptime: 17)
        try expect(controller.status == .preview && fake.creates.count == 3, "Demo scenes never create assertions")
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 18)
        controller.update(enabled: true, isPreview: false, liveChats: [chat(state: .interrupted)], now: now, uptime: 19)
        try expect(controller.status == .waiting && fake.released.last == 4, "Interrupt releases immediately")
    }

    private static func renewalAndFailures() throws {
        let fake = FakeClient()
        let controller = KeepAwakeController(client: fake)
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 10)
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now.addingTimeInterval(20), uptime: 69)
        try expect(fake.creates.count == 1, "Heartbeat does not churn native assertions")
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now.addingTimeInterval(20), uptime: 70)
        try expect(controller.assertionID == 2 && fake.released == [1], "Lease renews before native timeout")
        try expect(fake.operations == ["create:1", "create:2", "release:1"], "Renewal acquires before release, avoiding sleep gap")
        fake.createError = -1
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 130)
        try expect(controller.status == .failed && controller.assertionID == nil && fake.released == [1, 2], "Failed renewal releases its remaining lease")
        try expect(controller.lastError?.contains("ffffffff") == true, "IOKit failure appears in diagnostics")
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 131)
        try expect(fake.creates.count == 3, "Failure uses bounded retry delay")
        fake.createError = nil
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 160)
        try expect(controller.status == .active && controller.assertionID == 3 && controller.lastError == nil, "Transient native failure recovers without stale diagnostics")
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now.addingTimeInterval(3600), uptime: 161)
        try expect(controller.status == .waiting && controller.assertionID == nil, "Stale lifecycle releases instead of renewing forever")

        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 200)
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 400)
        try expect(controller.status == .active && controller.assertionID == 5, "A resumed heartbeat reacquires after native timeout")
        try expect(!fake.released.contains(4), "Already-expired native leases are not released a second time")
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: .nan)
        try expect(controller.status == .failed && controller.assertionID == nil, "Invalid monotonic clock fails safely")

        fake.releaseError = -2
        controller.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 500)
        controller.stop()
        try expect(controller.lastError?.contains("fffffffe") == true && controller.assertionID == nil, "Release errors remain diagnosable; native timeout remains a safety net")
    }

    private static func termination() throws {
        let fake = FakeClient()
        var controller: KeepAwakeController? = KeepAwakeController(client: fake)
        controller?.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 10)
        controller = nil
        try expect(fake.released == [1], "Deinitialization releases the live assertion")
        let second = KeepAwakeController(client: fake)
        second.update(enabled: true, isPreview: false, liveChats: [chat()], now: now, uptime: 20)
        second.stop(); second.stop()
        try expect(fake.released == [1, 2] && second.status == .off, "Explicit termination cleanup is idempotent")
    }

    private static func persistence() throws {
        try expect(!LocalData().keepAwakeEnabled, "New installations must leave keep-awake disabled")
        let decoder = JSONDecoder()
        let old = try decoder.decode(LocalData.self, from: Data("{}".utf8))
        try expect(!old.keepAwakeEnabled, "Older libraries without this preference remain disabled")
        let nullable = try decoder.decode(LocalData.self, from: Data("{\"keepAwakeEnabled\":null}".utf8))
        try expect(!nullable.keepAwakeEnabled, "Absent/null optional preferences migrate safely")
        var chosen = LocalData()
        chosen.keepAwakeEnabled = true
        chosen.labels["demo"] = "Example task"
        let encoded = try JSONEncoder().encode(chosen)
        let restored = try decoder.decode(LocalData.self, from: encoded)
        try expect(restored.keepAwakeEnabled, "An explicit user's enabled preference survives encoding")
        try expect(restored.labels == chosen.labels, "Saving power preferences preserves other library metadata")
        do {
            _ = try decoder.decode(LocalData.self, from: Data("{\"keepAwakeEnabled\":\"yes\"}".utf8))
            throw Failure(message: "Malformed preference must not silently enable keep-awake")
        } catch is DecodingError {
            checks += 1
        }
    }

    private final class FakeClient: KeepAwakeAssertionClient {
        var creates: [TimeInterval] = []
        var released: [UInt32] = []
        var operations: [String] = []
        var createError: Int32?
        var releaseError: Int32 = 0
        private var nextID: UInt32 = 0

        func create(timeout: TimeInterval) -> Result<UInt32, KeepAwakeNativeError> {
            creates.append(timeout)
            if let createError { return .failure(KeepAwakeNativeError(code: createError)) }
            nextID += 1
            operations.append("create:\(nextID)")
            return .success(nextID)
        }

        func release(_ assertionID: UInt32) -> Int32 {
            released.append(assertionID)
            operations.append("release:\(assertionID)")
            return releaseError
        }
    }

    private struct Failure: Error { let message: String }
}
