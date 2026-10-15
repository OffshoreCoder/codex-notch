import Foundation
@main struct TurnGroupTests {
    static func main() throws {
        var group = TurnGroup(turns: [GroupTurn(sessionID: "a", turnID: "1"), GroupTurn(sessionID: "b", turnID: "2")])
        func event(_ name: String, _ session: String, _ turn: String?) -> CompanionEvent {
            CompanionEvent(event: name, sessionID: session, turnID: turn, toolName: nil, toolUseID: nil, timestamp: Date())
        }
        group.receive(event("Stop", "a", "wrong"), accepted: true)
        assert(group.settled == 0)
        group.receive(event("Stop", "a", "1"), accepted: false)
        assert(group.settled == 0)
        group.receive(event("Stop", "a", "1"), accepted: true)
        assert(group.settled == 1 && !group.isComplete)
        group.receive(event("Interrupt", "b", "2"), accepted: true)
        assert(group.isComplete && group.interrupted == 1)
        group.receive(event("UserPromptSubmit", "a", "next"), accepted: true)
        assert(group.turns.count == 2 && group.isComplete)
        var restart = try JSONDecoder().decode(TurnGroup.self, from: JSONEncoder().encode(group))
        assert(restart == group)
        restart.notified = true
        assert(restart.notified)
        var replaced = TurnGroup(turns: [GroupTurn(sessionID: "a", turnID: "1")])
        replaced.receive(event("UserPromptSubmit", "a", "next"), accepted: true)
        assert(replaced.turns[0].status == .replaced)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(directory: dir)
        let now = Date()
        let chat = ChatSummary(id: "a", turnID: "1", state: .working, startedAt: now, updatedAt: now)
        store.startGroup([chat, chat])
        assert(store.data.turnGroup?.turns.count == 1 && store.isGrouped("a|1"))
        assert(LocalStore(directory: dir).data.turnGroup == store.data.turnGroup)
        store.beginQuiet(seconds: nil)
        store.receiveGroup(event("Stop", "a", "1"), accepted: true, current: chat)
        assert(store.pollGroupNotice() == nil)
        store.record(CompletedTurn(sessionID: "a", turnID: "1", startedAt: now, finishedAt: now))
        assert(store.endQuiet() == 1)
        assert(store.pollGroupNotice() == nil && store.data.turnGroup?.notified == true)
        print("Turn groups: 13 checks passed")
    }
}
