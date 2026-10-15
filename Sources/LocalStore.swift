import Foundation

struct CompletedTurn: Codable, Equatable, Identifiable {
    let sessionID: String
    let turnID: String
    let startedAt: Date?
    let finishedAt: Date
    var id: String { sessionID + "|" + turnID }
}

enum ReminderKind: String, Codable { case result, duration }
struct LocalReminder: Codable, Equatable, Identifiable {
    let id: String
    let kind: ReminderKind
    let sessionID: String
    let turnID: String
    let dueAt: Date
    var targetKey: String { sessionID + "|" + turnID }
}

enum AttentionKind: String, Codable { case question, review }
struct AttentionRequest: Codable, Equatable, Identifiable {
    let sessionID: String
    let turnID: String
    let kind: AttentionKind
    let requestedAt: Date
    var id: String { sessionID + "|" + turnID }
    var state: CompanionState { kind == .question ? .needsAnswer : .needsReview }
}

struct LocalData: Codable {
    var completions: [CompletedTurn] = []
    var seenCompletions: [String] = []
    var chats: [String: ChatSummary] = [:]
    var labels: [String: String] = [:]
    var keepAwakeEnabled = false
    var headphoneAccessoryEnabled = false
    var characterSkin = "robot"
    var screenSharing = false
    var archivedChats: [String: Date] = [:]
    var turnGroup: TurnGroup? = nil
    var reviewedResults: [String: Date] = [:]
    var reviewingIDs: [String] = []
    var results: [String: TurnResult] = [:]
    var workingDirectories: [String: String] = [:]
    var lastRealEvent: Date?
    var importantSessionID: String?
    var quietUntil: Date?
    var quietStartedAt: Date?
    var quietIndefinitely = false
    var deferredCompletionIDs: [String] = []
    var reminders: [LocalReminder] = []
    var deferredReminders: [LocalReminder] = []
    var attention: [String: AttentionRequest] = [:]
    var seenAttention: [String] = []
    var deferredAttentionIDs: [String] = []

    init() {}
    enum CodingKeys: String, CodingKey { case completions, seenCompletions, chats, labels, workingDirectories, results, reviewingIDs, reviewedResults, turnGroup, archivedChats, screenSharing, characterSkin, keepAwakeEnabled, headphoneAccessoryEnabled, lastRealEvent, importantSessionID, quietUntil, quietStartedAt, quietIndefinitely, deferredCompletionIDs, reminders, deferredReminders, attention, seenAttention, deferredAttentionIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completions = try c.decodeIfPresent([CompletedTurn].self, forKey: .completions) ?? []
        seenCompletions = try c.decodeIfPresent([String].self, forKey: .seenCompletions) ?? []
        chats = try c.decodeIfPresent([String: ChatSummary].self, forKey: .chats) ?? [:]
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        keepAwakeEnabled = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeEnabled) ?? false
        headphoneAccessoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .headphoneAccessoryEnabled) ?? false
        characterSkin = try c.decodeIfPresent(String.self, forKey: .characterSkin) ?? "robot"
        screenSharing = try c.decodeIfPresent(Bool.self, forKey: .screenSharing) ?? false
        archivedChats = try c.decodeIfPresent([String: Date].self, forKey: .archivedChats) ?? [:]
        turnGroup = try c.decodeIfPresent(TurnGroup.self, forKey: .turnGroup)
        reviewedResults = try c.decodeIfPresent([String: Date].self, forKey: .reviewedResults) ?? [:]
        reviewingIDs = try c.decodeIfPresent([String].self, forKey: .reviewingIDs) ?? []
        results = try c.decodeIfPresent([String: TurnResult].self, forKey: .results) ?? [:]
        workingDirectories = try c.decodeIfPresent([String: String].self, forKey: .workingDirectories) ?? [:]
        lastRealEvent = try c.decodeIfPresent(Date.self, forKey: .lastRealEvent)
        importantSessionID = try c.decodeIfPresent(String.self, forKey: .importantSessionID)
        quietUntil = try c.decodeIfPresent(Date.self, forKey: .quietUntil)
        quietStartedAt = try c.decodeIfPresent(Date.self, forKey: .quietStartedAt)
        quietIndefinitely = try c.decodeIfPresent(Bool.self, forKey: .quietIndefinitely) ?? false
        deferredCompletionIDs = try c.decodeIfPresent([String].self, forKey: .deferredCompletionIDs) ?? []
        reminders = try c.decodeIfPresent([LocalReminder].self, forKey: .reminders) ?? []
        deferredReminders = try c.decodeIfPresent([LocalReminder].self, forKey: .deferredReminders) ?? []
        attention = try c.decodeIfPresent([String: AttentionRequest].self, forKey: .attention) ?? [:]
        seenAttention = try c.decodeIfPresent([String].self, forKey: .seenAttention) ?? []
        deferredAttentionIDs = try c.decodeIfPresent([String].self, forKey: .deferredAttentionIDs) ?? []
    }
}

/// Deliberately stores metadata only. A corrupt file is left untouched for recovery.
final class LocalStore {
    private(set) var data = LocalData()
    private(set) var error: String?
    private let directory: URL
    private var canWrite = true
    private var url: URL { directory.appendingPathComponent("library.json") }

    init(directory: URL) {
        self.directory = directory
        do {
            try EventSpool(directory: directory).prepare()
            if FileManager.default.fileExists(atPath: url.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 16 * 1024 * 1024 else {
                    throw CocoaError(.fileReadNoPermission)
                }
                data = try JSONDecoder().decode(LocalData.self, from: Data(contentsOf: url))
            }
        } catch {
            self.error = "Локальная очередь недоступна: \(error.localizedDescription)"
            canWrite = false
        }
    }

    @discardableResult func record(_ completion: CompletedTurn, now: Date = Date(), deferNotification: Bool = false) -> Bool {
        guard !data.seenCompletions.contains(completion.id) else { return false }
        let quiet = isQuiet(now: now) || deferNotification
        update {
            if quiet { $0.deferredCompletionIDs = Array(($0.deferredCompletionIDs + [completion.id]).suffix(512)) }
            $0.archivedChats.removeValue(forKey: completion.sessionID)
            $0.completions.append(completion)
            $0.completions = Array($0.completions.suffix(512))
            $0.seenCompletions.append(completion.id)
            $0.seenCompletions = Array($0.seenCompletions.suffix(4096))
        }
        return true
    }

    func canArchive(_ sessionID: String, liveChat: ChatSummary? = nil, now: Date = Date()) -> Bool {
        let chat = liveChat ?? data.chats[sessionID]
        let active = chat.map { [.working, .coding, .checking].contains($0.state) && now.timeIntervalSince($0.updatedAt) < CompanionModel.staleAfter } ?? false
        return !active && !data.completions.contains { $0.sessionID == sessionID } &&
            !data.attention.values.contains { $0.sessionID == sessionID } &&
            !data.reviewingIDs.contains { $0.hasPrefix(sessionID + "|") } &&
            !data.reminders.contains { $0.sessionID == sessionID } &&
            !data.deferredReminders.contains { $0.sessionID == sessionID } &&
            !(data.turnGroup?.turns.contains { $0.sessionID == sessionID && $0.status == .running } ?? false)
    }
    func archive(_ sessionID: String, liveChat: ChatSummary? = nil, now: Date = Date()) {
        guard canArchive(sessionID, liveChat: liveChat, now: now), data.chats[sessionID] != nil else { return }
        update { $0.archivedChats[sessionID] = now; if $0.importantSessionID == sessionID { $0.importantSessionID = nil } }
    }
    func restoreArchive(_ sessionID: String) { update { $0.archivedChats.removeValue(forKey: sessionID) } }
    func restoreForEvent(_ event: CompanionEvent, accepted: Bool) {
        guard accepted, ["UserPromptSubmit", "PreToolUse"].contains(event.event),
              let archived = data.archivedChats[event.sessionID], event.timestamp > archived else { return }
        restoreArchive(event.sessionID)
    }

    func startGroup(_ chats: [ChatSummary]) {
        var keys = Set<String>()
        let turns = chats.compactMap { chat -> GroupTurn? in
            guard [.working, .coding, .checking].contains(chat.state), let turn = chat.turnID else { return nil }
            let item = GroupTurn(sessionID: chat.id, turnID: turn)
            return keys.insert(item.id).inserted ? item : nil
        }
        guard !turns.isEmpty else { return }
        update { $0.turnGroup = TurnGroup(turns: Array(turns.prefix(32))) }
    }
    func cancelGroup() { update { $0.turnGroup = nil } }
    func isGrouped(_ key: String) -> Bool {
        guard let group = data.turnGroup, !group.notified else { return false }
        return group.turns.contains { $0.id == key }
    }
    func receiveGroup(_ event: CompanionEvent, accepted: Bool, current: ChatSummary?) {
        guard var group = data.turnGroup else { return }
        var scoped = event
        if scoped.turnID == nil, ["Stop", "Interrupt"].contains(event.event), let turn = current?.turnID {
            scoped = CompanionEvent(event: event.event, sessionID: event.sessionID, turnID: turn,
                toolName: nil, toolUseID: nil, timestamp: event.timestamp)
        }
        group.receive(scoped, accepted: accepted)
        guard group != data.turnGroup else { return }
        update { $0.turnGroup = group }
    }
    func pollGroupNotice() -> String? {
        guard let group = data.turnGroup, group.isComplete, !group.notified, !isQuiet(), !quietExpired() else { return nil }
        update { $0.turnGroup?.notified = true }
        return group.text
    }

    @discardableResult func receiveResult(_ event: CompanionEvent, current: ChatSummary?) -> Bool {
        guard event.event == "Result", let result = event.result, let current,
              result.sessionID == event.sessionID, result.turnID == event.turnID,
              current.id == result.sessionID, current.turnID == result.turnID,
              event.timestamp >= current.updatedAt, ![.idle, .interrupted].contains(current.state),
              data.results[result.id].map({ $0.timestamp < result.timestamp && ($0.path != result.path || $0.checks != result.checks) }) ?? true else { return false }
        update {
            $0.archivedChats.removeValue(forKey: event.sessionID)
            $0.results[result.id] = result
            if $0.results.count > 512 {
                $0.results = Dictionary(uniqueKeysWithValues: $0.results.values.sorted { $0.timestamp > $1.timestamp }.prefix(512).map { ($0.id, $0) })
            }
        }
        return true
    }

    func rememberWorkingDirectory(_ event: CompanionEvent) {
        guard let path = event.workingDirectory, data.workingDirectories[event.sessionID] != path,
              ["SessionStart", "UserPromptSubmit"].contains(event.event) || data.workingDirectories[event.sessionID] == nil else { return }
        update {
            $0.workingDirectories[event.sessionID] = path
            if $0.workingDirectories.count > 256 {
                for key in $0.workingDirectories.keys.sorted().filter({ $0 != event.sessionID }).prefix($0.workingDirectories.count - 256) { $0.workingDirectories.removeValue(forKey: key) }
            }
        }
    }

    func selectImportant(_ sessionID: String?) { update { $0.importantSessionID = sessionID } }
    func shouldNotify(_ sessionID: String, now: Date = Date()) -> Bool {
        !isQuiet(now: now) && (data.importantSessionID == nil || data.importantSessionID == sessionID)
    }
    func isQuiet(now: Date = Date()) -> Bool {
        (data.quietStartedAt.map { now >= $0 } ?? true) &&
            (data.quietIndefinitely || (data.quietUntil.map { $0 > now } ?? false))
    }
    func beginQuiet(seconds: TimeInterval?, now: Date = Date()) {
        update { $0.quietIndefinitely = seconds == nil; $0.quietStartedAt = now; $0.quietUntil = seconds.map { now.addingTimeInterval($0) } }
    }
    /// Returns one summary count; viewed results and unselected chats never reappear.
    @discardableResult func endQuiet() -> Int {
        let completionKeys = data.completions.filter {
            data.deferredCompletionIDs.contains($0.id) && !isGrouped($0.id) &&
                (data.importantSessionID == nil || data.importantSessionID == $0.sessionID)
        }.map(\.id)
        let reminderKeys = data.deferredReminders.filter { reminder in
            if reminder.kind == .result { return data.completions.contains { $0.id == reminder.targetKey } }
            return data.chats[reminder.sessionID]?.turnID == reminder.turnID &&
                [.working, .coding, .checking].contains(data.chats[reminder.sessionID]?.state ?? .unknown)
        }.map(\.targetKey)
        let attentionKeys = data.attention.values.filter {
            data.deferredAttentionIDs.contains($0.id) && (data.importantSessionID == nil || data.importantSessionID == $0.sessionID)
        }.map(\.id)
        let groupDue = data.turnGroup.map { $0.isComplete && !$0.notified } ?? false
        let count = Set(completionKeys + reminderKeys + attentionKeys).count + (groupDue ? 1 : 0)
        update {
            if groupDue { $0.turnGroup?.notified = true }
            $0.quietIndefinitely = false; $0.quietUntil = nil; $0.quietStartedAt = nil
            $0.deferredCompletionIDs.removeAll(); $0.deferredReminders.removeAll(); $0.deferredAttentionIDs.removeAll()
        }
        return count
    }
    func quietExpired(now: Date = Date()) -> Bool {
        !data.quietIndefinitely && (data.quietUntil.map { $0 <= now } ?? false)
    }

    func remindResult(_ sessionID: String, after seconds: TimeInterval, now: Date = Date()) {
        guard seconds > 0, let result = data.completions.last(where: { $0.sessionID == sessionID }) else { return }
        schedule(LocalReminder(id: UUID().uuidString, kind: .result, sessionID: sessionID,
            turnID: result.turnID, dueAt: now.addingTimeInterval(seconds)))
    }
    func watchDuration(_ chat: ChatSummary, threshold: TimeInterval) {
        guard threshold > 0, let turn = chat.turnID, let start = chat.startedAt,
              [.working, .coding, .checking].contains(chat.state) else { return }
        schedule(LocalReminder(id: UUID().uuidString, kind: .duration, sessionID: chat.id,
            turnID: turn, dueAt: start.addingTimeInterval(threshold)))
    }
    private func schedule(_ reminder: LocalReminder) {
        update {
            $0.reminders.removeAll { $0.sessionID == reminder.sessionID && $0.kind == reminder.kind }
            $0.deferredReminders.removeAll { $0.sessionID == reminder.sessionID && $0.kind == reminder.kind }
            $0.reminders.append(reminder)
            $0.reminders = Array($0.reminders.suffix(512))
        }
    }
    func cancelReminders(_ sessionID: String) {
        update {
            $0.reminders.removeAll { $0.sessionID == sessionID }
            $0.deferredReminders.removeAll { $0.sessionID == sessionID }
        }
    }
    /// A duration reminder needs a freshly observed matching turn, including after restart.
    func pollReminders(liveChats: [ChatSummary], now: Date = Date()) -> [LocalReminder] {
        var due: [LocalReminder] = []
        var keep: [LocalReminder] = []
        for reminder in data.reminders {
            if reminder.kind == .result {
                guard data.completions.contains(where: { $0.id == reminder.targetKey }) else { continue }
            } else {
                guard let chat = liveChats.first(where: { $0.id == reminder.sessionID }) else {
                    if let known = data.chats[reminder.sessionID],
                       known.turnID != reminder.turnID || [.idle, .finished, .interrupted].contains(known.state) { continue }
                    keep.append(reminder); continue
                }
                guard chat.turnID == reminder.turnID,
                      ![.finished, .interrupted, .idle].contains(chat.state) else { continue }
                guard [.working, .coding, .checking].contains(chat.state) else { keep.append(reminder); continue }
            }
            if reminder.dueAt <= now { due.append(reminder) } else { keep.append(reminder) }
        }
        guard !due.isEmpty || keep != data.reminders else { return [] }
        let quiet = isQuiet(now: now) || quietExpired(now: now)
        update {
            $0.reminders = keep
            if quiet { $0.deferredReminders = Array(($0.deferredReminders + due).suffix(512)) }
        }
        return quiet ? [] : due
    }

    /// Only a scoped explicit signal can create attention; Stop and tool results preserve it.
    @discardableResult func receiveAttention(_ event: CompanionEvent, current: ChatSummary?, deferNotification: Bool = false) -> Bool {
        guard CompanionEvent.attentionEvents.contains(event.event), let turn = event.turnID,
              let current, current.id == event.sessionID, current.turnID == turn,
              event.timestamp >= current.updatedAt,
              ![.idle, .interrupted].contains(current.state) || event.event == "AttentionClear" else { return false }
        if event.event == "AttentionClear" {
            update { $0.attention.removeValue(forKey: event.sessionID + "|" + turn) }
            return false
        }
        let kind: AttentionKind = event.event == "AttentionQuestion" ? .question : .review
        let request = AttentionRequest(sessionID: event.sessionID, turnID: turn, kind: kind, requestedAt: event.timestamp)
        let key = request.id + "|" + kind.rawValue
        guard !data.seenAttention.contains(key) else { return false }
        let quiet = isQuiet(now: event.timestamp) || deferNotification
        update {
            $0.archivedChats.removeValue(forKey: event.sessionID)
            $0.attention = $0.attention.filter { $0.value.sessionID != event.sessionID }
            $0.attention[request.id] = request
            if $0.attention.count > 512 {
                $0.attention = Dictionary(uniqueKeysWithValues: $0.attention.values.sorted { $0.requestedAt > $1.requestedAt }
                    .prefix(512).map { ($0.id, $0) })
            }
            $0.seenAttention = Array(($0.seenAttention + [key]).suffix(4096))
            if quiet { $0.deferredAttentionIDs = Array(($0.deferredAttentionIDs + [request.id]).suffix(512)) }
        }
        return true
    }

    func clearAttention(sessionID: String) {
        update { $0.attention = $0.attention.filter { $0.value.sessionID != sessionID } }
    }

    func clearAttentionForLifecycle(_ event: CompanionEvent, accepted: Bool) {
        guard accepted, ["UserPromptSubmit", "Interrupt", "SessionEnd"].contains(event.event) else { return }
        update { data in
            data.attention = data.attention.filter {
                guard $0.value.sessionID == event.sessionID else { return true }
                return event.event != "UserPromptSubmit" && event.turnID != nil && event.turnID != $0.value.turnID
            }
        }
    }

    func endSession(_ sessionID: String, at date: Date) {
        update { data in
            data.reminders.removeAll { $0.sessionID == sessionID && $0.kind == .duration }
            data.deferredReminders.removeAll { $0.sessionID == sessionID && $0.kind == .duration }
            if let chat = data.chats[sessionID] {
                let terminal = [CompanionState.finished, .interrupted].contains(chat.state)
                data.chats[sessionID] = ChatSummary(id: sessionID, turnID: nil, state: terminal ? chat.state : .idle,
                    startedAt: terminal ? chat.startedAt : nil, updatedAt: date, endedAt: chat.endedAt)
            }
        }
    }

    func recordLastEvent(_ date: Date) {
        guard data.lastRealEvent == nil || date > data.lastRealEvent! else { return }
        update { $0.lastRealEvent = date }
    }

    func remember(_ chats: [ChatSummary]) {
        update { data in
            for chat in chats { data.chats[chat.id] = chat }
            if data.chats.count > 256 {
                let keep = data.chats.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(256)
                data.chats = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
                data.labels = data.labels.filter { self.data.chats[$0.key] != nil }
            }
        }
    }

    func rename(_ sessionID: String, to name: String) {
        let label = String(name.filter { !$0.isNewline && !$0.isASCIIControl }.prefix(80)).trimmingCharacters(in: .whitespaces)
        update { $0.labels[sessionID] = label.isEmpty ? nil : label }
    }
    func name(for sessionID: String) -> String { data.labels[sessionID] ?? "Чат " + String(sessionID.prefix(8)) }
    /// Opening is navigation. Explicit review requests and attached results require confirmation.
    func markOpened(_ key: String) {
        let unreviewedResult = data.results[key].map { $0.timestamp > (data.reviewedResults[key] ?? .distantPast) } ?? false
        let needsReview = unreviewedResult || data.attention[key]?.kind == .review || data.reviewingIDs.contains(key)
        if needsReview {
            guard !data.reviewingIDs.contains(key) else { return }
            update { $0.reviewingIDs = Array(($0.reviewingIDs + [key]).suffix(512)) }
        } else { acknowledge(key) }
    }
    func openChat(_ sessionID: String) {
        let keys = Set(data.completions.filter { $0.sessionID == sessionID }.map(\.id) +
            data.attention.values.filter { $0.sessionID == sessionID }.map(\.id))
        for key in keys { markOpened(key) }
    }

    func acknowledgeChat(_ sessionID: String) {
        update {
            for result in $0.results.values where result.sessionID == sessionID { $0.reviewedResults[result.id] = result.timestamp }
            $0.reviewingIDs.removeAll { $0.hasPrefix(sessionID + "|") }
            $0.completions.removeAll { $0.sessionID == sessionID }
            $0.attention = $0.attention.filter { $0.value.sessionID != sessionID }
        }
    }

    func acknowledge(_ id: String) { update { if let result = $0.results[id] { $0.reviewedResults[id] = result.timestamp }; $0.reviewingIDs.removeAll { $0 == id }; $0.completions.removeAll { $0.id == id }; $0.attention.removeValue(forKey: id) } }
    func acknowledgeAll() { update { for result in $0.results.values { $0.reviewedResults[result.id] = result.timestamp }; $0.reviewingIDs.removeAll(); $0.completions.removeAll(); $0.attention.removeAll() } }

    func update(_ change: (inout LocalData) -> Void) {
        change(&data)
        if data.reviewedResults.count > 4096 { data.reviewedResults = Dictionary(uniqueKeysWithValues: data.reviewedResults.sorted { $0.value > $1.value }.prefix(4096).map { ($0.key, $0.value) }) }
        guard canWrite else { return }
        do {
            try EventSpool(directory: directory).prepare()
            // Refuse a replaced symlink instead of modifying its target.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               attrs[.type] as? FileAttributeType != .typeRegular { throw CocoaError(.fileWriteNoPermission) }
            try JSONEncoder().encode(data).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            error = nil
        } catch { self.error = "Не удалось сохранить очередь: \(error.localizedDescription)" }
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
