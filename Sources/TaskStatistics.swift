import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local metadata only. A measured turn is a wall-clock interval, including tool
/// and human waiting. It is never CPU time, billable usage, or an estimate.
final class TaskStatistics {
    enum Period: Int, CaseIterable { case today, week, all
        var title: String { switch self { case .today: return "Сегодня"; case .week: return "7 дней"; case .all: return "Всё" } }
    }
    struct Record: Codable, Equatable {
        var sessionID: String
        var turnID: String
        var startedAt: Date
        var lastSeen: Date
        var endedAt: Date?
        var outcome: String?
        var id: String { sessionID + "|" + turnID }
    }
    struct DataSet: Codable {
        var version = 1
        var observedSince: Date
        var records: [Record] = []
        /// Missing means automatic; empty means explicitly not grouped.
        var assignments: [String: String] = [:]
        init(now: Date) { observedSince = now }
        enum CodingKeys: String, CodingKey { case version, observedSince, records, assignments }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            guard version == 1 else { throw CocoaError(.coderReadCorrupt) }
            observedSince = try c.decode(Date.self, forKey: .observedSince)
            records = try c.decodeIfPresent([Record].self, forKey: .records) ?? []
            assignments = try c.decodeIfPresent([String: String].self, forKey: .assignments) ?? [:]
        }
    }
    struct ChatRow {
        let sessionID: String
        let name: String
        let ticket: String?
        let automaticTicket: String?
        let hasManualAssignment: Bool
        let duration: TimeInterval
        let turns: Int
        let completed: Int
        let tokens: Int64?
    }
    struct GroupRow {
        let title: String
        let duration: TimeInterval
        let tokens: Int64?
        let tokenCoverage: Int
        let chats: [ChatRow]
    }
    struct Snapshot {
        let period: Period
        let summedDuration: TimeInterval
        let elapsedDuration: TimeInterval
        let turns: Int
        let completed: Int
        let groups: [GroupRow]
        let tokens: Int64?
        let tokenCoverage: Int
        let chatCount: Int
        let observedSince: Date
        let retainedSince: Date?
        let tokenDetail: String
        let error: String?
        let masked: Bool
        let collectionEnabled: Bool
    }

    private(set) var data: DataSet
    private(set) var error: String?
    private let directory: URL
    private var canWrite = true
    private var enabled = true
    private var knownIDs: Set<String> = []
    private var url: URL { directory.appendingPathComponent("statistics.json") }
    private static let maxRecords = 8192
    private static let maxSessions = 512
    var sessionIDs: [String] { Array(Set(data.records.map(\.sessionID))).sorted() }

    init(directory: URL, now: Date = Date()) {
        self.directory = directory
        data = DataSet(now: now)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var dirInfo = stat()
            guard lstat(directory.path, &dirInfo) == 0, dirInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), dirInfo.st_uid == geteuid() else { throw CocoaError(.fileReadNoPermission) }
            guard chmod(directory.path, 0o700) == 0 else { throw CocoaError(.fileReadNoPermission) }
            if FileManager.default.fileExists(atPath: url.path) {
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? file.close() }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= 4 * 1024 * 1024,
                      let bytes = try file.read(upToCount: 4 * 1024 * 1024) else { throw CocoaError(.fileReadNoPermission) }
                let decoded = try JSONDecoder().decode(DataSet.self, from: bytes)
                guard decoded.observedSince.timeIntervalSince1970.isFinite,
                      decoded.records.count <= Self.maxRecords,
                      decoded.assignments.count <= Self.maxSessions,
                      decoded.records.allSatisfy(Self.validRecord),
                      decoded.assignments.allSatisfy({ Self.session($0.key) != nil && ($0.value.isEmpty || Self.normalizedTicket($0.value) == $0.value) }) else { throw CocoaError(.coderReadCorrupt) }
                data = decoded
                // An app gap cannot establish ongoing work. Keep only the interval
                // that was observed, rather than counting the whole offline gap.
                var changed = false
                for index in data.records.indices where data.records[index].endedAt == nil {
                    data.records[index].endedAt = data.records[index].lastSeen
                    data.records[index].outcome = "observationEnded"
                    changed = true
                }
                if changed { save() }
            }
        } catch {
            self.error = "Статистика недоступна. Исходный файл сохранён."
            canWrite = false
        }
    }

    /// Call after root lifecycle acceptance. Child terminal events cannot end a root turn.
    func observe(event: CompanionEvent, accepted: Bool, current: ChatSummary?) {
        guard enabled, accepted, let id = Self.session(event.sessionID), event.timestamp.timeIntervalSince1970.isFinite,
              event.timestamp >= data.observedSince else { return }
        let now = event.timestamp
        if event.event == "UserPromptSubmit", let current, current.id == event.sessionID,
           let turn = current.turnID, let start = current.startedAt, start == now {
            let key = id + "|" + turn
            guard !data.records.contains(where: { $0.id == key }), Self.validTurn(turn) else { return }
            for index in data.records.indices where data.records[index].sessionID == id && data.records[index].endedAt == nil {
                data.records[index].endedAt = max(data.records[index].startedAt, min(now, data.records[index].lastSeen))
                data.records[index].outcome = "superseded"
            }
            data.records.append(Record(sessionID: id, turnID: turn, startedAt: start, lastSeen: now))
            bound()
            save()
            return
        }
        guard let index = data.records.lastIndex(where: { $0.sessionID == id && $0.endedAt == nil }),
              now >= data.records[index].lastSeen else { return }
        let record = data.records[index]
        if event.event != "SessionEnd", let turn = event.turnID, turn != record.turnID { return }
        guard CompanionEvent.hookEvents.contains(event.event) || CompanionEvent.attentionEvents.contains(event.event) else { return }
        data.records[index].lastSeen = now
        if ["Stop", "Interrupt", "SessionEnd"].contains(event.event) {
            data.records[index].endedAt = now
            data.records[index].outcome = event.event == "Stop" ? "completed" : event.event == "Interrupt" ? "interrupted" : "sessionEnded"
            save()
        }
        // Non-terminal events update in memory only; writes are bounded to turns.
    }

    /// End observation at sleep/shutdown; never imply that Codex itself completed.
    func suspend(now: Date = Date()) {
        var changed = false
        for index in data.records.indices where data.records[index].endedAt == nil {
            data.records[index].endedAt = max(data.records[index].startedAt, min(now, data.records[index].lastSeen))
            data.records[index].outcome = "observationEnded"
            changed = true
        }
        if changed { save() }
    }

    func setEnabled(_ enabled: Bool, now: Date = Date()) {
        if !enabled { suspend(now: now) }
        self.enabled = enabled
    }

    @discardableResult func assign(ticket: String?, to sessionID: String) -> Bool {
        guard let id = Self.session(sessionID), sessionIDs.contains(id) || knownIDs.contains(id),
              data.assignments[id] != nil || data.assignments.count < Self.maxSessions else { return false }
        if let ticket {
            guard ticket.isEmpty || Self.normalizedTicket(ticket) != nil else { return false }
            data.assignments[id] = ticket.isEmpty ? "" : Self.normalizedTicket(ticket)
        } else { data.assignments.removeValue(forKey: id) }
        save()
        return true
    }

    func reset(now: Date = Date()) {
        guard canWrite else { return }
        data = DataSet(now: now)
        save()
    }

    func snapshot(period: Period, names: [String: String], tokens: TaskTokenReader.Result, knownSessionIDs: [String] = [],
                  masked: Bool, now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        let boundary: Date
        switch period {
        case .today: boundary = calendar.startOfDay(for: now)
        case .week: boundary = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .all: boundary = .distantPast
        }
        let relevant = data.records.filter { $0.startedAt <= now && effectiveEnd($0, now: now) >= boundary }
        let allIDs = Array(Set(relevant.map(\.sessionID) + knownSessionIDs.prefix(Self.maxSessions).compactMap(Self.session))).sorted()
        knownIDs = Set(knownSessionIDs.prefix(Self.maxSessions).compactMap(Self.session))
        let intervals = relevant.compactMap { record -> DateInterval? in
            let start = max(boundary, record.startedAt), end = min(now, effectiveEnd(record, now: now))
            return end > start ? DateInterval(start: start, end: end) : nil
        }
        var rows: [ChatRow] = []
        for (index, id) in allIDs.enumerated() {
            let records = relevant.filter { $0.sessionID == id }
            let name = masked ? "Задача \(index + 1)" : Self.cleanName(names[id]) ?? "Чат \(String(id.prefix(8)))"
            let auto = Self.ticket(in: names[id] ?? "")
            let assignment = data.assignments[id]
            let ticket: String? = assignment == nil ? auto : (assignment!.isEmpty ? nil : assignment!)
            let duration = records.reduce(0.0) { $0 + max(0, min(now, effectiveEnd($1, now: now)).timeIntervalSince(max(boundary, $1.startedAt))) }
            rows.append(ChatRow(sessionID: id, name: name, ticket: masked ? nil : ticket,
                                automaticTicket: masked ? nil : auto, hasManualAssignment: assignment != nil,
                                duration: duration, turns: records.count,
                                completed: records.filter { $0.outcome == "completed" && ($0.endedAt ?? now) >= boundary }.count,
                                tokens: tokens.values[id]))
        }
        var groups: [GroupRow] = []
        for (key, group) in Dictionary(grouping: rows, by: { $0.ticket ?? "" }) {
            let values = group.compactMap(\.tokens)
            groups.append(GroupRow(title: key.isEmpty ? (masked ? "Задачи" : "Без тикета") : key,
                                   duration: group.reduce(0) { $0 + $1.duration }, tokens: values.isEmpty ? nil : Self.sum(values),
                                   tokenCoverage: values.count, chats: group.sorted { $0.duration > $1.duration }))
        }
        groups.sort { $0.duration > $1.duration }
        let values = rows.compactMap(\.tokens)
        return Snapshot(period: period, summedDuration: intervals.reduce(0) { $0 + $1.duration },
                        elapsedDuration: Self.unionDuration(intervals), turns: relevant.count,
                        completed: relevant.filter { $0.outcome == "completed" }.count, groups: groups,
                        tokens: values.isEmpty ? nil : Self.sum(values), tokenCoverage: values.count, chatCount: rows.count,
                        observedSince: data.observedSince, retainedSince: data.records.map(\.startedAt).min(),
                        tokenDetail: tokens.detail, error: error, masked: masked, collectionEnabled: enabled)
    }

    static func ticket(in name: String) -> String? {
        let source = String(name.prefix(500))
        guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])[A-Z][A-Z0-9]{1,14}-[1-9][0-9]{0,8}(?![A-Za-z0-9])") else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: range).compactMap { Range($0.range, in: source).map { String(source[$0]) } }
        let unique = Set(matches)
        return unique.count == 1 ? unique.first : nil
    }
    static func normalizedTicket(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ticket(in: value) == value ? value : nil
    }
    static func durationText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(min(seconds.isFinite ? seconds : 0, 1e12)))
        return value < 60 ? "\(value) с" : value < 3600 ? "\(value / 60) мин" : "\(value / 3600) ч \(value % 3600 / 60) мин"
    }
    static func tokenText(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    private func effectiveEnd(_ record: Record, now: Date) -> Date {
        record.endedAt ?? min(now, record.lastSeen.addingTimeInterval(CompanionModel.staleAfter))
    }
    private static func unionDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var running = sorted.first else { return 0 }
        var total: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.start <= running.end { running = DateInterval(start: running.start, end: max(running.end, interval.end)) }
            else { total += running.duration; running = interval }
        }
        return total + running.duration
    }
    private static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { let result = $0.addingReportingOverflow($1); return result.overflow ? Int64.max : result.partialValue }
    }
    private static func session(_ raw: String) -> String? {
        guard raw.utf8.count == 36, let uuid = UUID(uuidString: raw) else { return nil }; return uuid.uuidString.lowercased()
    }
    private static func validTurn(_ raw: String) -> Bool {
        !raw.isEmpty && raw.utf8.count <= 256 && raw.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.:/".unicodeScalars.contains($0) }
    }
    private static func validRecord(_ value: Record) -> Bool {
        session(value.sessionID) == value.sessionID && validTurn(value.turnID) &&
        value.startedAt.timeIntervalSince1970.isFinite && value.lastSeen.timeIntervalSince1970.isFinite &&
        value.lastSeen >= value.startedAt && (value.endedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= value.startedAt && $0 <= value.lastSeen } ?? true) &&
        (value.outcome.map { ["completed", "interrupted", "sessionEnded", "observationEnded", "superseded"].contains($0) } ?? true)
    }
    private static func cleanName(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
    private func bound() {
        data.records = Array(data.records.suffix(Self.maxRecords))
        let ids = Set(data.records.reversed().map(\.sessionID).reduce(into: [String]()) { if !$0.contains($1) && $0.count < Self.maxSessions { $0.append($1) } })
        data.records.removeAll { !ids.contains($0.sessionID) }
        // Keep explicit assignments for token-only known chats as well as timed
        // records. These carry no name or content and remain bounded separately.
        if data.assignments.count > Self.maxSessions {
            data.assignments = Dictionary(uniqueKeysWithValues: data.assignments.sorted { $0.key < $1.key }.prefix(Self.maxSessions).map { ($0.key, $0.value) })
        }
    }
    private func save() {
        guard canWrite else { return }
        do {
            let bytes = try JSONEncoder().encode(data)
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            error = nil
        } catch { self.error = "Не удалось сохранить локальную статистику." }
    }
}

/// Internal Codex metadata is optional and version-dependent. No transcripts,
/// generated titles, paths, prompts, or tool output are queried.
struct TaskTokenReader {
    enum Status { case available, unavailable, incompatible, failed }
    struct Result {
        let values: [String: Int64]
        let status: Status
        let detail: String
        static let unavailable = Result(values: [:], status: .unavailable, detail: "Счётчик токенов Codex пока недоступен.")
    }
    private let directory: URL
    private let databaseURL: URL?
    init(directory: URL = ThreadNames.defaultDirectory, databaseURL: URL? = nil) {
        self.directory = directory
        if let databaseURL { self.databaseURL = databaseURL }
        else if let path = ProcessInfo.processInfo.environment["CODEX_NOTCH_STATE_DB"], !path.isEmpty { self.databaseURL = URL(fileURLWithPath: path) }
        else { self.databaseURL = nil }
    }
    func read(sessionIDs: [String]) -> Result {
        let ids = Array(Set(sessionIDs.prefix(512).compactMap { raw -> String? in
            guard raw.utf8.count == 36, let id = UUID(uuidString: raw) else { return nil }; return id.uuidString.lowercased()
        })).sorted()
        guard let url = databaseURL ?? discover(), safeDatabase(url) else { return .unavailable }
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard opened == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; return .unavailable }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = ids.isEmpty ? "SELECT id, tokens_used FROM threads WHERE 0" : "SELECT id, tokens_used FROM threads WHERE id IN (" + placeholders + ")"
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return Result(values: [:], status: prepared == SQLITE_ERROR ? .incompatible : .failed,
                          detail: "В этой версии локальной базы Codex счётчик токенов недоступен.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, id) in ids.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), id, -1, transient) }
        let allowed = Set(ids)
        var values: [String: Int64] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return Result(values: [:], status: .failed, detail: "Локальный счётчик Codex временно недоступен.") }
            guard sqlite3_column_type(statement, 0) == SQLITE_TEXT, sqlite3_column_bytes(statement, 0) == 36,
                  let bytes = sqlite3_column_text(statement, 0), sqlite3_column_type(statement, 1) == SQLITE_INTEGER else { continue }
            let id = String(decoding: UnsafeBufferPointer(start: bytes, count: 36), as: UTF8.self)
            let value = sqlite3_column_int64(statement, 1)
            if allowed.contains(id), value >= 0 { values[id] = value }
        }
        return Result(values: values, status: .available,
                      detail: "Текущий счётчик threads.tokens_used для известных чатов. Это внутреннее поле Codex; разбивка по ходам и дням, input/output и стоимость недоступны.")
    }
    private func discover() -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.compactMap { url -> (UInt64, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            let raw = name.dropFirst(6).dropLast(7)
            guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let version = UInt64(raw) else { return nil }
            return (version, url)
        }.sorted { $0.0 > $1.0 }.first?.1
    }
    private func safeDatabase(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              let header = try? file.read(upToCount: 100), header.count == 100,
              header.prefix(16) == Data("SQLite format 3\0".utf8) else { return false }
        if header[18] == 2 || header[19] == 2 {
            for suffix in ["-wal", "-shm"] {
                var sidecar = stat()
                guard lstat(url.path + suffix, &sidecar) == 0, sidecar.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return false }
            }
        }
        return true
    }
}
