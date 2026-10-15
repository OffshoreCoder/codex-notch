import Foundation

@main struct AttentionTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexNotch-attention-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let session = "00112233-4455-6677-8899-aabbccddeeff"
        let otherSession = "ffeeddcc-bbaa-9988-7766-554433221100"
        let turn = "turn-1"
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), message)
        }
        func event(_ name: String, sessionID: String? = nil, turnID: String? = "turn-1", offset: Double = 0) -> CompanionEvent {
            CompanionEvent(event: name, sessionID: sessionID ?? session, turnID: turnID,
                           toolName: nil, toolUseID: nil, timestamp: now.addingTimeInterval(offset))
        }
        func chat(sessionID: String? = nil, turnID: String? = "turn-1", offset: Double = -1) -> ChatSummary {
            ChatSummary(id: sessionID ?? session, turnID: turnID, state: .working,
                        startedAt: now.addingTimeInterval(-30), updatedAt: now.addingTimeInterval(offset))
        }
        func hook(_ marker: String, tool: String = "Bash", key: String = "command", name: String = "PostToolUse", includeTurn: Bool = true) throws -> Data {
            var object: [String: Any] = [
                "hook_event_name": name, "session_id": session, "tool_name": tool,
                "tool_use_id": "call-1", "tool_input": [key: marker],
                "prompt": "private-prompt-sentinel", "tool_response": "private-result-sentinel",
                "transcript_path": "/private/transcript-sentinel.jsonl"
            ]
            if includeTurn { object["turn_id"] = turn }
            return try JSONSerialization.data(withJSONObject: object)
        }

        // Explicit no-op declarations are accepted only after their own shell call ends.
        for (marker, expectedName) in [(": codex-notch:question", "AttentionQuestion"),
                                       (": codex-notch:review", "AttentionReview"),
                                       (": codex-notch:clear", "AttentionClear")] {
            for (tool, key) in [("Bash", "command"), ("exec_command", "cmd"), ("shell_command", "command")] {
                let data = try hook(marker, tool: tool, key: key)
                let signal = CompanionEvent.attentionFromHook(data, now: now)
                expect(signal?.event == expectedName, "exact shell marker maps to its declaration")
                expect(signal?.sessionID == session && signal?.turnID == turn, "hook scopes declaration to actual chat and turn")
                expect(signal?.toolName == nil && signal?.toolUseID == nil, "signal drops shell-call metadata")
                expect(CompanionEvent.fromHook(data, now: now)?.event == "PostToolUse", "normal tool lifecycle remains available")
            }
        }
        for invalid in [" : codex-notch:question", ": codex-notch:question\n", ": codex-notch:question; true",
                        "echo ': codex-notch:question'", ": codex-notch:question # note", ": codex-notch:permission"] {
            let signal = CompanionEvent.attentionFromHook(try hook(invalid), now: now)
            expect(signal == nil, "embedded or modified marker is never interpreted as shell code")
        }
        for name in ["PreToolUse", "PermissionRequest", "Stop", "AttentionQuestion"] {
            let signal = CompanionEvent.attentionFromHook(try hook(": codex-notch:question", name: name), now: now)
            expect(signal == nil, "only completed explicit tool calls create attention")
        }
        for (tool, key) in [("apply_patch", "command"), ("functions.exec", "code"), ("mcp__shell__run", "command"), ("exec_command", "command")] {
            let signal = CompanionEvent.attentionFromHook(try hook(": codex-notch:question", tool: tool, key: key), now: now)
            expect(signal == nil, "unknown tools and argument shapes do not create attention")
        }
        let missingTurn = CompanionEvent.attentionFromHook(try hook(": codex-notch:question", includeTurn: false), now: now)
        expect(missingTurn == nil, "unscoped marker cannot target a guessed turn")
        expect(CompanionEvent.attentionFromHook(Data("invalid JSON".utf8), now: now) == nil, "invalid hook JSON is ignored")
        let parsed = CompanionEvent.attentionFromHook(try hook(": codex-notch:question"), now: now)!
        let encoded = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
        for sensitive in ["codex-notch:question", "private-prompt-sentinel", "private-result-sentinel", "transcript-sentinel", "command", "tool_input"] {
            expect(!encoded.contains(sensitive), "attention event persists no command, prompt, result or transcript")
        }

        let explicit = CompanionEvent.explicitAttention(kind: "question", session: session.uppercased(), turn: turn, now: now)
        expect(explicit?.event == "AttentionQuestion" && explicit?.sessionID == session, "manual signal validates and normalizes UUID")
        for kind in ["permission", "Question", "", "question; true"] {
            expect(CompanionEvent.explicitAttention(kind: kind, session: session, turn: turn, now: now) == nil, "manual kind is an exact allowlist")
        }
        expect(CompanionEvent.explicitAttention(kind: "review", session: "latest", turn: turn, now: now) == nil, "manual session must be explicit UUID")
        for invalidTurn in ["", "turn with spaces", "turn\n", String(repeating: "a", count: 257)] {
            expect(CompanionEvent.explicitAttention(kind: "review", session: session, turn: invalidTurn, now: now) == nil, "manual turn must be a bounded identifier")
        }

        let store = LocalStore(directory: directory)
        expect(!store.receiveAttention(event("PermissionRequest"), current: chat()), "policy checking never creates user attention")
        expect(!store.receiveAttention(parsed, current: nil), "missing current chat never guesses a target")
        expect(!store.receiveAttention(parsed, current: chat(sessionID: otherSession)), "different chat cannot receive signal")
        expect(!store.receiveAttention(parsed, current: chat(turnID: "turn-2")), "old turn cannot override current turn")
        expect(!store.receiveAttention(parsed, current: chat(offset: 1)), "old signal cannot override newer observed activity")
        expect(!store.receiveAttention(event("AttentionQuestion", turnID: nil), current: chat(turnID: nil)), "missing turn cannot create attention")
        expect(store.receiveAttention(parsed, current: chat()), "matching explicit question accepted once")
        expect(store.data.attention[session + "|" + turn]?.state == .needsAnswer, "question has distinct answer state")
        expect(!store.receiveAttention(event("AttentionQuestion", offset: 1), current: chat()), "repeated declaration does not notify again")
        let restored = LocalStore(directory: directory)
        expect(restored.data.attention == store.data.attention, "pending question survives restart")
        expect(!restored.receiveAttention(parsed, current: chat()), "deduplication survives restart")
        expect(restored.receiveAttention(event("AttentionReview", offset: 2), current: chat()), "a real review declaration can replace question")
        expect(restored.data.attention.count == 1 && restored.data.attention.values.first?.state == .needsReview, "one pending request per chat")

        for name in ["Stop", "PostToolUse", "PreToolUse", "PermissionRequest"] {
            restored.clearAttentionForLifecycle(event(name, offset: 3), accepted: true)
            expect(restored.data.attention.count == 1, "Stop and ordinary tool events preserve explicit request")
        }
        restored.clearAttentionForLifecycle(event("UserPromptSubmit", turnID: "turn-2", offset: 4), accepted: false)
        expect(restored.data.attention.count == 1, "rejected stale lifecycle cannot clear request")
        restored.clearAttentionForLifecycle(event("Interrupt", turnID: "other-turn", offset: 4), accepted: true)
        expect(restored.data.attention.count == 1, "another turn interruption cannot clear request")
        restored.clearAttentionForLifecycle(event("SessionEnd", sessionID: otherSession, turnID: nil, offset: 4), accepted: true)
        expect(restored.data.attention.count == 1, "another chat ending cannot clear request")
        restored.clearAttentionForLifecycle(event("UserPromptSubmit", turnID: "turn-2", offset: 4), accepted: true)
        expect(restored.data.attention.isEmpty, "new prompt answers or supersedes prior request")
        expect(!restored.receiveAttention(event("AttentionReview", offset: 5), current: chat()), "old acknowledged request cannot reappear")

        expect(restored.receiveAttention(event("AttentionQuestion", turnID: "turn-2", offset: 5), current: chat(turnID: "turn-2")), "next turn can declare a new request")
        expect(!restored.receiveAttention(event("AttentionClear", turnID: "turn-2", offset: 6), current: chat(turnID: "turn-2")), "explicit clear is not a new notification")
        expect(restored.data.attention.isEmpty, "explicit clear removes its scoped request")
        expect(restored.receiveAttention(event("AttentionReview", turnID: "turn-3", offset: 7), current: chat(turnID: "turn-3")), "another turn can request review")
        restored.acknowledgeChat(session)
        expect(restored.data.attention.isEmpty, "viewed action clears explicit attention")
        expect(restored.receiveAttention(event("AttentionQuestion", turnID: "turn-4", offset: 8), current: chat(turnID: "turn-4")), "later request accepted")
        restored.clearAttentionForLifecycle(event("Interrupt", turnID: "turn-4", offset: 9), accepted: true)
        expect(restored.data.attention.isEmpty, "matching interruption clears request")
        expect(restored.receiveAttention(event("AttentionQuestion", turnID: "turn-5", offset: 10), current: chat(turnID: "turn-5")), "new turn request accepted before session end")
        restored.clearAttentionForLifecycle(event("SessionEnd", turnID: nil, offset: 11), accepted: true)
        expect(restored.data.attention.isEmpty, "session end clears requests for that session")

        let quietDirectory = directory.appendingPathComponent("quiet")
        let quiet = LocalStore(directory: quietDirectory)
        quiet.beginQuiet(seconds: 60, now: now)
        expect(quiet.receiveAttention(parsed, current: chat()), "quiet mode retains explicit request")
        expect(!quiet.shouldNotify(session, now: now), "quiet mode suppresses immediate notification")
        _ = quiet.record(CompletedTurn(sessionID: session, turnID: turn, startedAt: nil, finishedAt: now), now: now)
        let quietRestored = LocalStore(directory: quietDirectory)
        expect(quietRestored.endQuiet() == 1, "quiet summary counts one chat-turn with both request and completion once")
        expect(quietRestored.endQuiet() == 0, "quiet summary is emitted only once")
        expect(quietRestored.data.attention.count == 1, "summary does not silently acknowledge request")

        // Model regressions: fallback identities and session removal follow accepted lifecycle.
        var model = CompanionModel()
        let firstStop = event("Stop", turnID: nil)
        model.receive(firstStop)
        let firstCompletion = model.completion(for: firstStop)!
        let repeatedStop = event("Stop", turnID: nil, offset: 1)
        model.receive(repeatedStop)
        let repeatedCompletion = model.completion(for: repeatedStop)!
        expect(firstCompletion == repeatedCompletion, "missing-turn duplicate Stop retains identity and first completion time")
        let completionStore = LocalStore(directory: directory.appendingPathComponent("completions"))
        expect(completionStore.record(firstCompletion), "first orphan Stop is queued")
        expect(!completionStore.record(repeatedCompletion), "duplicate orphan Stop cannot enqueue or notify again")
        model.receive(event("UserPromptSubmit", turnID: nil, offset: 2))
        let identifiedStop = event("Stop", turnID: "identified-turn", offset: 3)
        model.receive(identifiedStop)
        expect(model.completion(for: identifiedStop)?.turnID == "identified-turn", "explicit Stop ID replaces synthetic prompt identity")
        model.receive(event("UserPromptSubmit", turnID: "new-turn", offset: 5))
        model.receive(event("SessionEnd", turnID: nil, offset: 4))
        expect(model.snapshot(now: now.addingTimeInterval(6)).state == .working, "older SessionEnd cannot delete a newer running turn")
        model.receive(event("SessionEnd", turnID: nil, offset: 7))
        expect(model.snapshot(now: now.addingTimeInterval(8)).state == .idle, "fresh SessionEnd removes that session")
        print("Attention markers, explicit scope, privacy, persistence, quiet summary and lifecycle: \(checks) checks passed")
    }
}
