import Foundation

enum CompanionState: String, Codable {
    case idle, working, coding, checking, finished, interrupted, unknown, needsAnswer, needsReview

    /// Only confirmed lifecycle outcomes may automatically interrupt the user.
    /// PermissionRequest precedes policy/auto-review and does not prove a dialog exists.
    var automaticAttentionDuration: TimeInterval {
        switch self {
        case .finished: return 8
        case .interrupted: return 4
        default: return 0
        }
    }
}

struct CompanionSnapshot: Codable {
    let state: CompanionState
    let sessionID: String?
    let activeCount: Int
    let updatedAt: Date
}

struct ChatSummary: Codable, Equatable {
    let id: String
    let turnID: String?
    let state: CompanionState
    let startedAt: Date?
    let updatedAt: Date
    var endedAt: Date? = nil
}

/// Bounded event metadata, root directory and explicitly attached result only.
/// No prompt, arbitrary command, code, tool output or transcript.
struct CompanionEvent: Codable {
    let event: String
    let sessionID: String
    let turnID: String?
    let toolName: String?
    let toolUseID: String?
    let timestamp: Date
    var workingDirectory: String? = nil
    var result: TurnResult? = nil

    static let hookEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "Stop", "Interrupt", "SessionEnd"
    ]

    static let attentionEvents: Set<String> = ["AttentionQuestion", "AttentionReview", "AttentionClear"]
    static let supported = hookEvents.union(attentionEvents).union(["Result"])

    /// An explicit, exact no-op marker. Never inspect or retain arbitrary command content.
    static func attentionFromHook(_ data: Data, now: Date = Date()) -> CompanionEvent? {
        guard let base = fromHook(data, now: now), base.event == "PostToolUse", base.turnID != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = object["tool_input"] as? [String: Any] else { return nil }
        let command: String?
        switch base.toolName {
        case "Bash", "shell_command": command = input["command"] as? String
        case "exec_command": command = input["cmd"] as? String
        default: return nil
        }
        let names = [": codex-notch:question": "AttentionQuestion",
                     ": codex-notch:review": "AttentionReview", ": codex-notch:clear": "AttentionClear"]
        guard let command, let event = names[command] else { return nil }
        return CompanionEvent(event: event, sessionID: base.sessionID, turnID: base.turnID,
                              toolName: nil, toolUseID: nil, timestamp: now)
    }

    static func resultFromHook(_ data: Data, now: Date = Date()) -> CompanionEvent? {
        guard let base = fromHook(data, now: now), base.event == "PostToolUse", let turn = base.turnID,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = object["tool_input"] as? [String: Any] else { return nil }
        let command: String?
        switch base.toolName {
        case "Bash", "shell_command": command = input["command"] as? String
        case "exec_command": command = input["cmd"] as? String
        default: return nil
        }
        guard let command, let result = ResultSignal.parse(command: command, sessionID: base.sessionID, turnID: turn, now: now) else { return nil }
        var event = CompanionEvent(event: "Result", sessionID: base.sessionID, turnID: turn,
                                   toolName: nil, toolUseID: nil, timestamp: now)
        event.result = result
        return event
    }

    static func explicitAttention(kind: String, session: String, turn: String, now: Date = Date()) -> CompanionEvent? {
        let names = ["question": "AttentionQuestion", "review": "AttentionReview", "clear": "AttentionClear"]
        guard let name = names[kind], UUID(uuidString: session) != nil, let validTurn = identifier(turn) else { return nil }
        return CompanionEvent(event: name, sessionID: session.lowercased(), turnID: validTurn,
                              toolName: nil, toolUseID: nil, timestamp: now)
    }

    static func fromHook(_ data: Data, now: Date = Date()) -> CompanionEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["hook_event_name"] as? String, hookEvents.contains(event),
              let session = identifier(object["session_id"]) else { return nil }
        var result = CompanionEvent(event: event, sessionID: session,
                              turnID: identifier(object["turn_id"]),
                              toolName: identifier(object["tool_name"]),
                              toolUseID: identifier(object["tool_use_id"]), timestamp: now)
        if let cwd = object["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 2048,
           !cwd.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
           !cwd.split(separator: "/").contains("..") {
            result.workingDirectory = URL(fileURLWithPath: cwd).standardizedFileURL.path
        }
        return result
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256,
              text.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0)
              }) else { return nil }
        return text
    }
}

/// Main-turn lifecycle wins over late child-tool events. Separate chats remain separate.
struct CompanionModel {
    private struct Session {
        var state: CompanionState = .idle
        var rootTurn: String?
        var turnKey: String?
        var startedAt: Date?
        var endedAt: Date?
        var terminal = false
        var tools: [String: String] = [:]
        var requests: Set<String> = []
        var lastEvent = Date.distantPast
        var lastCoding = Date.distantPast
    }
    private var sessions: [String: Session] = [:]
    static let staleAfter: TimeInterval = 30 * 60

    mutating func receive(_ event: CompanionEvent) {
        guard CompanionEvent.hookEvents.contains(event.event) else { return }
        var session = sessions[event.sessionID] ?? Session()
        guard event.timestamp >= session.lastEvent else { return }
        if event.event == "SessionEnd" { sessions.removeValue(forKey: event.sessionID); return }
        // A tool finishing in a child after root Stop must not resurrect the chat.
        if session.terminal && ["PreToolUse", "PostToolUse", "PermissionRequest"].contains(event.event) {
            return
        }
        switch event.event {
        case "SessionStart":
            // Resume/start is not evidence of a running turn.
            if session.lastEvent == .distantPast { session.state = .idle }
        case "UserPromptSubmit":
            session.rootTurn = event.turnID
            session.turnKey = event.turnID ?? "local-\(event.timestamp.timeIntervalSince1970)"
            session.startedAt = event.timestamp
            session.endedAt = nil
            session.terminal = false
            session.tools.removeAll()
            session.requests.removeAll()
            session.lastCoding = .distantPast
            session.state = .working
        case "PreToolUse":
            session.tools[toolKey(event)] = event.toolName ?? "tool"
            if ["apply_patch", "Edit", "Write"].contains(event.toolName ?? "") {
                session.lastCoding = event.timestamp
            }
            session.state = runningState(session)
        case "PermissionRequest":
            // Codex currently provides no permission-resolved event or tool_use_id here.
            session.requests.insert(requestKey(event))
            session.state = .checking
        case "PostToolUse":
            session.tools.removeValue(forKey: toolKey(event))
            // PermissionRequest has no call id. A parallel invocation of the same tool
            // finishing is not evidence that the invocation needing approval resumed.
            let turnPrefix = (event.turnID ?? "") + ":"
            let sameToolOutstanding = session.tools.contains {
                $0.key.hasPrefix(turnPrefix) && $0.value == (event.toolName ?? "tool")
            }
            if !sameToolOutstanding { session.requests.remove(requestKey(event)) }
            session.state = runningState(session)
        case "Stop", "Interrupt":
            // Ignore an explicitly different turn when the root turn is known.
            if let root = session.rootTurn, let turn = event.turnID, root != turn { return }
            if !session.terminal {
                session.rootTurn = session.rootTurn ?? event.turnID
                session.turnKey = event.turnID ?? session.turnKey ?? "stop-\(event.timestamp.timeIntervalSince1970)"
                session.endedAt = event.timestamp
            }
            session.state = event.event == "Stop" ? .finished : .interrupted
            session.terminal = true
            session.tools.removeAll()
            session.requests.removeAll()
        default: break
        }
        session.lastEvent = event.timestamp
        sessions[event.sessionID] = session
        // Bound memory even if the host never emits SessionEnd.
        if sessions.count > 256 {
            for key in sessions.sorted(by: { $0.value.lastEvent < $1.value.lastEvent })
                .prefix(sessions.count - 256).map(\.key) { sessions.removeValue(forKey: key) }
        }
    }

    func snapshot(now: Date = Date()) -> CompanionSnapshot {
        let fresh = sessions.filter { now.timeIntervalSince($0.value.lastEvent) < Self.staleAfter }
            .mapValues { original -> Session in
                var session = original
                // Fast edits often start and finish between two UI polls. Keep a short
                // visible pulse, without overriding approval requests or terminal states.
                let age = now.timeIntervalSince(session.lastCoding)
                if session.state == .working && age >= 0 && age < 1.25 { session.state = .coding }
                return session
            }
        let active = fresh.filter { [.working, .coding, .checking].contains($0.value.state) }
        let selected = (active.isEmpty ? fresh : active).sorted {
            let l = priority($0.value.state), r = priority($1.value.state)
            return l == r ? $0.value.lastEvent > $1.value.lastEvent : l > r
        }.first
        return CompanionSnapshot(state: selected?.value.state ?? (sessions.isEmpty ? .idle : .unknown),
                                 sessionID: selected?.key, activeCount: active.count,
                                 updatedAt: selected?.value.lastEvent ?? now)
    }

    func chatSummaries(now: Date = Date()) -> [ChatSummary] {
        sessions.map { id, session in
            ChatSummary(id: id, turnID: session.turnKey,
                        state: [.working, .coding, .checking].contains(session.state) && now.timeIntervalSince(session.lastEvent) >= Self.staleAfter ? .unknown : session.state,
                        startedAt: session.startedAt, updatedAt: session.lastEvent, endedAt: session.endedAt)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func completion(for event: CompanionEvent) -> CompletedTurn? {
        guard event.event == "Stop", let session = sessions[event.sessionID],
              session.state == .finished, session.lastEvent == event.timestamp else { return nil }
        return CompletedTurn(sessionID: event.sessionID,
                             turnID: session.turnKey ?? event.turnID ?? "stop-\(event.timestamp.timeIntervalSince1970)",
                             startedAt: session.startedAt, finishedAt: session.endedAt ?? event.timestamp)
    }

    private func runningState(_ session: Session) -> CompanionState {
        if !session.requests.isEmpty { return .checking }
        return session.tools.values.contains(where: { ["apply_patch", "Edit", "Write"].contains($0) })
            ? .coding : .working
    }
    private func toolKey(_ event: CompanionEvent) -> String {
        (event.turnID ?? "") + ":" + (event.toolUseID ?? event.toolName ?? "tool")
    }
    private func requestKey(_ event: CompanionEvent) -> String {
        (event.turnID ?? "") + ":" + (event.toolName ?? "tool")
    }
    private func priority(_ state: CompanionState) -> Int {
        switch state {
        case .needsAnswer, .needsReview: return 7
        case .checking: return 6
        case .coding: return 5
        case .working: return 4
        case .finished: return 3
        case .interrupted: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }
}
