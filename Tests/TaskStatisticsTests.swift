import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct TaskStatisticsTests {
    static var checks = 0
    static let a = "00112233-4455-6677-8899-aabbccddeeff"
    static let b = "ffeeddcc-bbaa-9988-7766-554433221100"
    static let c = "aabbccdd-1122-3344-5566-77889900aabb"
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let fm = FileManager.default
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("CodexNotchStatisticsTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        try observedIntervals(root)
        try assignmentAndPrivacy(root)
        try periodsAndParallelism(root)
        try persistenceAndGaps(root)
        try safeStorage(root)
        try tokens(root)
        try tokenSafety(root)
        print("PASS: TaskStatistics (\(checks) checks)")
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(message: message) }
    }
    static func event(_ name: String, _ id: String = a, _ turn: String? = "turn-1", _ offset: Double) -> CompanionEvent {
        CompanionEvent(event: name, sessionID: id, turnID: turn, toolName: nil, toolUseID: nil, timestamp: base.addingTimeInterval(offset))
    }
    static func start(_ stats: TaskStatistics, _ id: String = a, _ turn: String = "turn-1", _ offset: Double = 0) {
        let e = event("UserPromptSubmit", id, turn, offset)
        let chat = ChatSummary(id: id, turnID: turn, state: .working, startedAt: e.timestamp, updatedAt: e.timestamp)
        stats.observe(event: e, accepted: true, current: chat)
    }
    static func receive(_ stats: TaskStatistics, _ name: String, _ id: String = a, _ turn: String? = "turn-1", _ offset: Double, accepted: Bool = true) {
        stats.observe(event: event(name, id, turn, offset), accepted: accepted, current: nil)
    }
    static func snap(_ stats: TaskStatistics, offset: Double = 1000, names: [String: String] = [:], period: TaskStatistics.Period = .all, ids: [String] = [], tokenValues: [String: Int64] = [:], masked: Bool = false, calendar: Calendar = .current) -> TaskStatistics.Snapshot {
        stats.snapshot(period: period, names: names, tokens: TaskTokenReader.Result(values: tokenValues, status: .available, detail: "numeric only"), knownSessionIDs: ids, masked: masked, now: base.addingTimeInterval(offset), calendar: calendar)
    }
    static func observedIntervals(_ root: URL) throws {
        let stats = TaskStatistics(directory: root.appendingPathComponent("intervals"), now: base)
        start(stats, a, "old-spool-turn", -100)
        try expect(stats.data.records.isEmpty, "Events predating observation/reset cannot backfill timing")
        receive(stats, "Stop", a, "turn-1", 5)
        try expect(stats.data.records.isEmpty, "Stop without observed start cannot invent timing")
        start(stats)
        start(stats)
        try expect(stats.data.records.count == 1 && stats.data.records[0].endedAt == nil, "Duplicate start must not close the same turn")
        receive(stats, "PostToolUse", a, "child-turn", 10)
        try expect(stats.data.records[0].lastSeen == base, "Child turn event must not alter root observation")
        receive(stats, "Stop", a, "child-turn", 20)
        try expect(stats.data.records[0].endedAt == nil, "Child terminal event cannot close root")
        receive(stats, "Stop", a, "turn-1", 30, accepted: false)
        try expect(stats.data.records[0].endedAt == nil, "Rejected lifecycle cannot close a record")
        receive(stats, "PermissionRequest", a, "turn-1", 40)
        try expect(stats.data.records[0].endedAt == nil, "Permission-policy checking does not mean turn ended or user blocked")
        receive(stats, "Stop", a, "turn-1", 60)
        try expect(snap(stats).summedDuration == 60, "Observed root start and Stop produce wall-clock duration")
        try expect(snap(stats).completed == 1 && snap(stats).turns == 1, "Only Stop counts a completed turn")
        receive(stats, "Stop", a, "turn-1", 120)
        try expect(snap(stats).summedDuration == 60, "Repeated terminal cannot extend duration")
        start(stats, a, "turn-2", 180)
        receive(stats, "Interrupt", a, "turn-2", 200)
        try expect(snap(stats).summedDuration == 80 && snap(stats).completed == 1, "Interrupted interval adds time but is not completed")
        start(stats, a, "turn-3", 300)
        receive(stats, "SessionEnd", a, nil, 310)
        try expect(snap(stats).summedDuration == 90, "Accepted session end closes interval conservatively")
        try expect(snap(stats).completed == 1, "Session end is not task success")
        try expect(snap(stats).tokens == nil, "No synthetic tokens from time")
        let missingID = TaskStatistics(directory: root.appendingPathComponent("missing-turn-id"), now: base)
        let noIDPrompt = event("UserPromptSubmit", a, nil, 0)
        let localKey = "local-\(base.timeIntervalSince1970)"
        missingID.observe(event: noIDPrompt, accepted: true,
            current: ChatSummary(id: a, turnID: localKey, state: .working, startedAt: base, updatedAt: base))
        receive(missingID, "PostToolUse", a, "child-id", 10)
        try expect(missingID.data.records[0].turnID == localKey, "Child event cannot rename an unknown root ID")
        let rootStop = event("Stop", a, "actual-root-id", 60)
        missingID.observe(event: rootStop, accepted: true,
            current: ChatSummary(id: a, turnID: "actual-root-id", state: .finished, startedAt: base, updatedAt: rootStop.timestamp, endedAt: rootStop.timestamp))
        try expect(snap(missingID).summedDuration == 60 && snap(missingID).completed == 1, "Accepted terminal may close an exact-start root whose prompt omitted turn_id")
        try expect(missingID.data.records[0].turnID == "actual-root-id", "Adopted terminal identity persists for root accounting")
    }
    static func assignmentAndPrivacy(_ root: URL) throws {
        let dir = root.appendingPathComponent("privacy")
        let stats = TaskStatistics(directory: dir, now: base)
        start(stats); receive(stats, "Stop", a, "turn-1", 60)
        let name = "JP-1234 private-chat-name-sentinel"
        let result = snap(stats, names: [a: name], ids: [a, b], tokenValues: [a: 12345, b: 67890])
        try expect(result.groups.contains { $0.title == "JP-1234" }, "Exactly one ticket in assigned chat name groups automatically")
        try expect(result.chatCount == 2 && result.tokenCoverage == 2, "Known older chats retain token coverage with no fabricated intervals")
        let prior = result.groups.flatMap(\.chats).first { $0.sessionID == b }!
        try expect(prior.turns == 0 && prior.duration == 0, "Prior chat timing must remain unobserved")
        try expect(stats.assign(ticket: "jp-555", to: b), "Known token-only chat can be assigned a ticket")
        start(stats, a, "another-turn", 100)
        receive(stats, "Stop", a, "another-turn", 110)
        try expect(stats.data.assignments[b] == "JP-555", "New timed turns must not discard prior-chat manual assignment")
        try expect(snap(stats, ids: [a, b]).groups.contains { $0.title == "JP-555" }, "Manual prior-chat ticket is applied")
        try expect(stats.assign(ticket: "", to: a), "Explicit no-ticket assignment is accepted")
        try expect(snap(stats, names: [a: name]).groups[0].title == "Без тикета", "Explicit no-ticket must suppress automatic grouping")
        try expect(stats.assign(ticket: nil, to: a), "Automatic assignment can be restored")
        try expect(snap(stats, names: [a: name]).groups[0].title == "JP-1234", "Automatic name extraction returns after reset")
        try expect(!stats.assign(ticket: "JP-44", to: c), "Unknown IDs cannot receive assignment")
        try expect(!stats.assign(ticket: "JP-12 and JP-13", to: a), "Multiple tickets cannot silently pick one manual group")
        try expect(TaskStatistics.ticket(in: "JP-12 JP-12") == "JP-12", "Repeated same ticket remains unambiguous")
        try expect(TaskStatistics.ticket(in: "JP-12 JP-13") == nil, "Different tickets do not silently misattribute a chat")
        try expect(TaskStatistics.ticket(in: "file abc-JP-3.swift") == "JP-3", "Delimited ticket works")
        try expect(TaskStatistics.ticket(in: "notjp-12") == nil && TaskStatistics.ticket(in: "JP-0") == nil, "No case-insensitive guessing or zero issue")
        let bytes = try Data(contentsOf: dir.appendingPathComponent("statistics.json"))
        let saved = String(decoding: bytes, as: UTF8.self)
        try expect(!saved.contains("private-chat-name-sentinel") && !saved.contains("12345") && !saved.contains("67890"), "No chat names or token counters persisted")
        try expect(!saved.contains("tool_name") && !saved.contains("command") && !saved.contains("prompt"), "Persisted schema has no content or tools")
        let masked = snap(stats, names: [a: name], ids: [a, b], masked: true)
        try expect(!masked.groups.contains { $0.title.contains("JP-") }, "Sharing hides ticket names")
        try expect(masked.groups.flatMap(\.chats).allSatisfy { !$0.name.contains("private") && $0.ticket == nil && $0.automaticTicket == nil }, "Sharing masks names and ticket metadata")
    }
    static func periodsAndParallelism(_ root: URL) throws {
        let stats = TaskStatistics(directory: root.appendingPathComponent("periods"), now: base)
        start(stats, a, "a", 0); start(stats, b, "b", 30)
        receive(stats, "Stop", a, "a", 90); receive(stats, "Stop", b, "b", 120)
        let result = snap(stats)
        try expect(result.summedDuration == 180, "Parallel chat turn durations sum separately")
        try expect(result.elapsedDuration == 120, "Elapsed union does not double count overlapping chats")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: base.addingTimeInterval(86400))
        let offset = midnight.timeIntervalSince(base)
        start(stats, c, "midnight", offset - 60)
        receive(stats, "Stop", c, "midnight", offset + 120)
        let today = snap(stats, offset: offset + 500, period: .today, calendar: calendar)
        try expect(today.summedDuration == 120, "Interval spanning midnight is clipped to selected local day")
        let week = snap(stats, offset: offset + 500, period: .week, calendar: calendar)
        try expect(week.summedDuration == 360, "Week includes observed prior-day timing")
        let tokenToday = snap(stats, offset: offset + 500, period: .today, ids: [a], tokenValues: [a: 99999], calendar: calendar)
        try expect(tokenToday.tokens == 99999, "Lifetime counter is displayed without fake daily allocation")
        try expect(TaskStatistics.durationText(3661) == "1 ч 1 мин", "Duration formatting is compact")
        try expect(TaskStatistics.tokenText(nil) == "—", "Unavailable token source remains explicitly absent")
    }
    static func persistenceAndGaps(_ root: URL) throws {
        let dir = root.appendingPathComponent("gaps")
        var stats = TaskStatistics(directory: dir, now: base)
        start(stats)
        receive(stats, "PostToolUse", a, "turn-1", 30)
        stats.suspend(now: base.addingTimeInterval(100))
        try expect(snap(stats).summedDuration == 30, "Sleep closes at last observed event, not sleep timestamp")
        receive(stats, "Stop", a, "turn-1", 500)
        try expect(snap(stats).summedDuration == 30, "Post-sleep Stop cannot count unobserved gap")
        start(stats, a, "new-turn", 600)
        stats.setEnabled(false, now: base.addingTimeInterval(700))
        try expect(!snap(stats).collectionEnabled, "Disabled observation is visible in statistics presentation")
        start(stats, b, "disabled-turn", 800)
        try expect(stats.data.records.count == 2, "Disabled statistics do not observe new events")
        stats.setEnabled(true)
        start(stats, a, "restart", 900)
        let before = stats.data.records.count
        stats = TaskStatistics(directory: dir, now: base.addingTimeInterval(2000))
        try expect(stats.data.records.count == before && stats.data.records.allSatisfy { $0.endedAt != nil }, "Restart retains records but terminates uncertain ongoing observation")
        try expect(snap(stats, offset: 5000).summedDuration == 30, "App downtime is not counted as work")
        stats.reset(now: base.addingTimeInterval(6000))
        try expect(stats.data.records.isEmpty && stats.data.observedSince == base.addingTimeInterval(6000), "Reset clears local observation and begins new coverage boundary")
        try expect(TaskStatistics(directory: dir).data.records.isEmpty, "Reset persists")
    }
    static func safeStorage(_ root: URL) throws {
        let dir = root.appendingPathComponent("storage")
        let stats = TaskStatistics(directory: dir, now: base)
        start(stats)
        let dirAttrs = try fm.attributesOfItem(atPath: dir.path)
        let file = dir.appendingPathComponent("statistics.json")
        let attrs = try fm.attributesOfItem(atPath: file.path)
        try expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Statistics directory is private")
        try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Statistics file is private")
        let broken = Data("private-corrupt-sentinel".utf8)
        try broken.write(to: file)
        let corrupt = TaskStatistics(directory: dir)
        start(corrupt)
        try expect(corrupt.error != nil && (try Data(contentsOf: file)) == broken, "Corrupt file is preserved and never overwritten")
        let linkDir = root.appendingPathComponent("linked-storage")
        try fm.createSymbolicLink(at: linkDir, withDestinationURL: dir)
        let linked = TaskStatistics(directory: linkDir)
        try expect(linked.error != nil, "Symlink statistics directory is refused")
        let migration = root.appendingPathComponent("migration")
        try fm.createDirectory(at: migration, withIntermediateDirectories: false)
        let legacy = "{\"observedSince\":\(base.timeIntervalSinceReferenceDate)}"
        try Data(legacy.utf8).write(to: migration.appendingPathComponent("statistics.json"))
        let migrated = TaskStatistics(directory: migration)
        try expect(migrated.error == nil && migrated.data.records.isEmpty && migrated.data.assignments.isEmpty, "Missing optional metadata migrates safely")
    }
    static func tokens(_ root: URL) throws {
        let url = root.appendingPathComponent("tokens.sqlite")
        let db = try Database(url)
        try db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, tokens_used, title TEXT, first_user_message TEXT)")
        try db.insert(a, value: "123456")
        try db.insert(b, value: "987654")
        try db.insert(c, value: "-1")
        let before = try Data(contentsOf: url)
        let files = try fm.contentsOfDirectory(atPath: root.path).sorted()
        let reader = TaskTokenReader(databaseURL: url)
        let result = reader.read(sessionIDs: [a.uppercased(), c, "' OR 1=1 --"])
        try expect(result.status == .available && result.values == [a: 123456], "Only known canonical UUID integer counters are read; negative counters rejected")
        try expect(try Data(contentsOf: url) == before, "Read-only counter access does not mutate main database")
        try expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == files, "Counter read creates no sidecars in rollback mode")
        try expect(!result.detail.contains("sentinel"), "Diagnostics reveal no private values")
        try expect(reader.read(sessionIDs: []).values.isEmpty, "No known IDs means no counters")
        try expect(reader.read(sessionIDs: Array(repeating: "invalid", count: 512) + [b]).values.isEmpty, "Input scan is bounded to 512 supplied IDs")
        try db.execute("UPDATE threads SET tokens_used=1.25 WHERE id='\(a)'")
        try expect(reader.read(sessionIDs: [a]).values.isEmpty, "Floating values are not silently rounded")
        try db.execute("UPDATE threads SET tokens_used=0 WHERE id='\(a)'")
        try expect(reader.read(sessionIDs: [a]).values[a] == 0, "Real zero counter remains zero, not absent")
    }
    static func tokenSafety(_ root: URL) throws {
        let missing = root.appendingPathComponent("missing.sqlite")
        try expect(TaskTokenReader(databaseURL: missing).read(sessionIDs: [a]).status == .unavailable && !fm.fileExists(atPath: missing.path), "Missing database is never created")
        let schema = root.appendingPathComponent("schema.sqlite")
        let db = try Database(schema)
        try db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
        try expect(TaskTokenReader(databaseURL: schema).read(sessionIDs: [a]).status == .incompatible, "Schema changes gracefully disable counter")
        let link = root.appendingPathComponent("tokens-link.sqlite")
        try fm.createSymbolicLink(at: link, withDestinationURL: schema)
        try expect(TaskTokenReader(databaseURL: link).read(sessionIDs: [a]).status == .unavailable, "Database symlink is refused")
        let fifo = root.appendingPathComponent("fifo.sqlite")
        try expect(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture created")
        try expect(TaskTokenReader(databaseURL: fifo).read(sessionIDs: [a]).status == .unavailable, "Special file is refused without blocking")
        let wal = root.appendingPathComponent("wal.sqlite")
        let live = try Database(wal)
        try live.execute("PRAGMA journal_mode=WAL")
        try live.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, tokens_used INTEGER)")
        try live.insert(a, value: "42")
        let mainBefore = try Data(contentsOf: wal)
        let walBefore = try Data(contentsOf: URL(fileURLWithPath: wal.path + "-wal"))
        try expect(TaskTokenReader(databaseURL: wal).read(sessionIDs: [a]).values[a] == 42, "Live WAL counters remain readable")
        try expect(try Data(contentsOf: wal) == mainBefore, "Live read leaves main DB unchanged")
        try expect(try Data(contentsOf: URL(fileURLWithPath: wal.path + "-wal")) == walBefore, "Live read leaves WAL unchanged")
    }
    struct Failure: Error { let message: String }
    final class Database {
        var handle: OpaquePointer?
        init(_ url: URL) throws {
            guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw Failure(message: "Fixture DB open failed") }
        }
        deinit { sqlite3_close(handle) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: "Fixture SQL failed: \(sql)") }
        }
        func insert(_ id: String, value: String) throws {
            // Test IDs and numeric literals only; private sentinels are never returned by reader.
            let hasTitle = sqlite3_table_column_metadata(handle, nil, "threads", "title", nil, nil, nil, nil, nil) == SQLITE_OK
            try execute(hasTitle ? "INSERT INTO threads VALUES ('\(id)', \(value), 'private-title-sentinel', 'private-prompt-sentinel')" : "INSERT INTO threads VALUES ('\(id)', \(value))")
        }
    }
}
