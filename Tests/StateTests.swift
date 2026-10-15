import Foundation

@main
struct StateTests {
    static func main() throws {
        let now = Date()
        func event(_ name: String, session: String = "chat-a", turn: String = "turn-a",
                   tool: String? = nil, id: String? = nil, offset: Double = 0) -> CompanionEvent {
            CompanionEvent(event: name, sessionID: session, turnID: turn, toolName: tool,
                           toolUseID: id, timestamp: now.addingTimeInterval(offset))
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        var model = CompanionModel()
        model.receive(event("UserPromptSubmit"))
        expect(model.snapshot(now: now).state == .working, "prompt starts working")
        model.receive(event("PreToolUse", tool: "apply_patch", id: "edit-1", offset: 1))
        expect(model.snapshot(now: now).state == .coding, "edits show coding")
        model.receive(event("PermissionRequest", tool: "Bash", offset: 2))
        model.receive(event("PostToolUse", tool: "apply_patch", id: "edit-1", offset: 3))
        expect(model.snapshot(now: now).state == .checking, "unrelated result cannot dismiss policy checking")
        expect(model.snapshot(now: now).state.automaticAttentionDuration == 0,
               "PermissionRequest must not imply a human approval dialog or open a card")
        model.receive(event("PostToolUse", tool: "Bash", id: "shell-1", offset: 4))
        expect(model.snapshot(now: now).state == .working, "matching result dismisses approval")
        model.receive(event("Stop", turn: "child-turn", offset: 5))
        expect(model.snapshot(now: now).state == .working, "child turn cannot complete root")
        model.receive(event("Stop", offset: 6))
        model.receive(event("PostToolUse", turn: "child-turn", tool: "Bash", id: "child", offset: 7))
        expect(model.snapshot(now: now).state == .finished, "late child result cannot resurrect root")
        model.receive(event("UserPromptSubmit", session: "chat-b", turn: "turn-b", offset: 8))
        expect(model.snapshot(now: now).state == .working, "active chat beats another chat's finished badge")
        model.receive(event("PermissionRequest", session: "chat-c", turn: "turn-c", tool: "Bash", offset: 9))
        expect(model.snapshot(now: now).activeCount == 2, "count active chats independently")
        expect(model.snapshot(now: now).sessionID == "chat-c", "permission gets priority")
        expect(model.snapshot(now: now.addingTimeInterval(CompanionModel.staleAfter + 10)).state == .unknown,
               "lost lifecycle never remains working forever")
        model.receive(event("SessionEnd", session: "chat-c", offset: 10))
        expect(model.snapshot(now: now).sessionID == "chat-b", "ending one chat preserves another")
        model.receive(event("Interrupt", session: "chat-b", turn: "turn-b", offset: 11))
        model.receive(event("UserPromptSubmit", session: "chat-b", turn: "turn-b", offset: 8))
        expect(model.snapshot(now: now).activeCount == 0, "out of order old input cannot resume interrupted turn")

        var parallel = CompanionModel()
        parallel.receive(event("UserPromptSubmit"))
        parallel.receive(event("PreToolUse", tool: "Bash", id: "a", offset: 1))
        parallel.receive(event("PreToolUse", tool: "Bash", id: "b", offset: 2))
        parallel.receive(event("PermissionRequest", tool: "Bash", offset: 3))
        parallel.receive(event("PostToolUse", tool: "Bash", id: "b", offset: 4))
        expect(parallel.snapshot(now: now).state == .checking, "parallel same-tool result cannot dismiss policy checking")
        expect(parallel.snapshot(now: now.addingTimeInterval(60)).state.automaticAttentionDuration == 0,
               "a slow automatically approved tool must never become a false popup after a debounce")
        parallel.receive(event("PostToolUse", tool: "Bash", id: "a", offset: 5))
        expect(parallel.snapshot(now: now).state == .working, "all outstanding same-tool calls completed")

        var quickEdit = CompanionModel()
        quickEdit.receive(event("UserPromptSubmit"))
        quickEdit.receive(event("PreToolUse", tool: "apply_patch", id: "quick", offset: 1))
        quickEdit.receive(event("PostToolUse", tool: "apply_patch", id: "quick", offset: 1.01))
        expect(quickEdit.snapshot(now: now.addingTimeInterval(1.1)).state == .coding,
               "quick edits remain visible across UI polling")
        expect(quickEdit.snapshot(now: now.addingTimeInterval(2.3)).state == .working,
               "quick edit pulse expires")
        quickEdit.receive(event("Stop", offset: 1.02))
        expect(quickEdit.snapshot(now: now.addingTimeInterval(1.1)).state == .finished,
               "edit pulse cannot conceal completion")
        expect(CompanionState.finished.automaticAttentionDuration == 8, "confirmed completion still notifies")
        expect(CompanionState.interrupted.automaticAttentionDuration == 4, "confirmed interruption still notifies")

        let secret = "SECRET-PROMPT-CODE-NEVER-SAVE"
        let input = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse", "session_id": "chat-a", "turn_id": "turn-a",
            "tool_name": "Bash", "tool_use_id": "call-a", "prompt": secret,
            "tool_input": ["command": secret], "transcript_path": secret,
            "last_assistant_message": secret
        ])
        let sanitized = CompanionEvent.fromHook(input, now: now)!
        let serialized = String(data: try JSONEncoder().encode(sanitized), encoding: .utf8)!
        expect(!serialized.contains(secret), "on-disk schema must exclude all sensitive payloads")
        expect(CompanionEvent.fromHook(Data("{broken".utf8)) == nil, "malformed hook ignored")
        let childStop = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "SubagentStop", "session_id": "chat-a"
        ])
        expect(CompanionEvent.fromHook(childStop) == nil, "subagent stop is not root completion")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexNotch-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = EventSpool(directory: directory)
        for index in 0..<(EventSpool.limit + 5) {
            try spool.append(event("PreToolUse", tool: "Bash", id: "call-\(index)", offset: Double(index)))
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        expect((attrs[.posixPermissions] as! NSNumber).intValue & 0o777 == 0o700, "runtime directory is private")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        expect(files.count == EventSpool.limit, "offline event backlog is bounded")
        expect(tryFilePermissions(files[0]) == 0o600, "event files are private")
        let drained = spool.drain()
        expect(drained.count == EventSpool.limit, "all bounded events drain")
        expect(drained.first?.toolUseID == "call-5", "spool evicts oldest, not newest")
        expect(spool.drain().isEmpty, "events delivered once")

        let symlink = directory.appendingPathComponent("bad-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: directory)
        do {
            try EventSpool(directory: symlink).append(sanitized)
            preconditionFailure("runtime symlinks must be refused")
        } catch { /* expected */ }
        print("State/privacy/spool checks passed")
    }
    static func tryFilePermissions(_ url: URL) -> Int {
        let attrs = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as! NSNumber).intValue & 0o777
    }
}
