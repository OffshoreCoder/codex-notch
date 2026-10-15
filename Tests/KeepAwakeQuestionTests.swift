import Foundation
@main struct KeepAwakeQuestionTests {
    static func main() throws {
        let now = Date()
        var tracker = KeepAwakeQuestions()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(directory: directory)
        let chat = ChatSummary(id: "s", turnID: "t", state: .working, startedAt: now, updatedAt: now)
        func event(_ name: String, turn: String? = "t", delta: Double = 0) -> CompanionEvent {
            CompanionEvent(event: name, sessionID: "s", turnID: turn, toolName: nil, toolUseID: nil, timestamp: now.addingTimeInterval(delta))
        }
        let question = event("AttentionQuestion")
        let accepted = store.receiveAttention(question, current: chat)
        tracker.receive(question, current: chat, attentionAccepted: accepted, lifecycleAccepted: false)
        assert(tracker.blockedSessionIDs == ["s"])
        store.openChat("s")
        assert(store.data.attention["s|t"]?.kind == .question)
        assert(LocalStore(directory: directory).data.attention["s|t"]?.kind == .question)
        assert(KeepAwakePolicy.eligibleSessionIDs(enabled: true, isPreview: false, liveChats: [chat], blockedSessionIDs: tracker.blockedSessionIDs, now: now).isEmpty)
        store.acknowledgeChat("s")
        tracker.receive(event("PostToolUse", delta: 1), current: chat, attentionAccepted: false, lifecycleAccepted: true)
        assert(tracker.blockedSessionIDs == ["s"])
        tracker.receive(event("AttentionClear", turn: "wrong", delta: 2), current: chat, attentionAccepted: false, lifecycleAccepted: false)
        assert(tracker.blockedSessionIDs == ["s"])
        tracker.receive(event("UserPromptSubmit", turn: "new", delta: 3), current: chat, attentionAccepted: false, lifecycleAccepted: false)
        assert(tracker.blockedSessionIDs == ["s"])
        tracker.receive(event("UserPromptSubmit", turn: "new", delta: 3), current: chat, attentionAccepted: false, lifecycleAccepted: true)
        assert(tracker.blockedSessionIDs.isEmpty)
        tracker.receive(question, current: chat, attentionAccepted: true, lifecycleAccepted: false)
        tracker.receive(event("AttentionClear", delta: 4), current: chat, attentionAccepted: false, lifecycleAccepted: false)
        assert(tracker.blockedSessionIDs.isEmpty)
        print("PASS: keep-awake question/read lifecycle (9 checks)")
    }
}
