import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct ThreadNamesTests {
    private static var checks = 0
    private static let fm = FileManager.default
    private static let a = "00112233-4455-6677-8899-aabbccddeeff"
    private static let b = "ffeeddcc-bbaa-9988-7766-554433221100"
    private static let c = "aabbccdd-1122-3344-5566-77889900aabb"

    static func main() throws {
        // SQLite NOFOLLOW rejects macOS's /var alias even though Foundation preserves it.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("CodexNotchNamesTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        try scopeAndPrivacy(root)
        try boundsAndChanges(root)
        try numericDiscovery(root)
        try safeFailureModes(root)
        try liveWAL(root)
        print("PASS: ThreadNames (\(checks) checks)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(message: message) }
    }

    private static func reader(_ url: URL) -> ThreadNames {
        ThreadNames(directory: url.deletingLastPathComponent(), databaseURL: url)
    }

    private static func scopeAndPrivacy(_ root: URL) throws {
        let url = root.appendingPathComponent("privacy.sqlite")
        let database = try Database(url)
        try database.createTable()
        try database.insert(a, "My assigned name", title: "private-title-sentinel")
        try database.insert(b, "unknown-chat-name-sentinel", title: "private-preview-sentinel")
        try database.insert(c, nil, title: "never-use-title-sentinel")
        let before = try Data(contentsOf: url)
        let filenames = try fm.contentsOfDirectory(atPath: root.path).sorted()
        let result = reader(url).read(sessionIDs: [a.uppercased(), c, "' OR 1=1 --", "latest", "", a])
        try expect(result.status == .available, "Valid compatible database should be readable: \(result.status.rawValue), \(result.detail)")
        try expect(result.names == [a: "My assigned name"], "Only requested valid IDs with explicit names are returned")
        try expect(!result.detail.contains("private") && !result.detail.contains("sentinel"), "Health detail must reveal no database content")
        try expect(try Data(contentsOf: url) == before, "Reader must not modify main database")
        try expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == filenames, "Rollback-mode read must create no files")
        let empty = reader(url).read(sessionIDs: ["'; DROP TABLE threads; --"])
        try expect(empty.status == .available && empty.names.isEmpty, "Injection-like IDs are rejected without querying other chats")
        try expect(reader(url).read(sessionIDs: [a]).names[a] == "My assigned name", "Invalid IDs must not alter the database")
        try expect(reader(url).read(sessionIDs: []).names.isEmpty, "No observed IDs means no names are read")
    }

    private static func boundsAndChanges(_ root: URL) throws {
        let url = root.appendingPathComponent("changes.sqlite")
        let database = try Database(url)
        try database.createTable()
        try database.insert(a, " \tBuild\nreview\r\u{0000}\u{007F} ")
        try database.insert(b, String(repeating: "😀", count: 300))
        try database.insert(c, "  \n\t  ")
        let source = reader(url)
        var result = source.read(sessionIDs: [a, b, c])
        try expect(result.names[a] == "Buildreview", "Control characters and surrounding whitespace must be removed")
        try expect(result.names[b]?.count == 200, "Names must be bounded by characters, preserving Unicode")
        try expect(result.names[c] == nil, "Blank explicit names are ignored")
        try database.execute("UPDATE threads SET name=NULL")
        result = source.read(sessionIDs: [a, b, c])
        try expect(result.status == .available && result.names.isEmpty, "Cleared names must disappear on the next read")
        try database.execute("DELETE FROM threads")
        try expect(source.read(sessionIDs: [a]).names.isEmpty, "Deleted chats must not retain cached names in the source")
        try database.insert(a, "Bounded lookup")
        let capped = source.read(sessionIDs: Array(repeating: "invalid", count: 512) + [a])
        try expect(capped.names.isEmpty, "At most 512 supplied IDs are inspected")
    }

    private static func numericDiscovery(_ root: URL) throws {
        let directory = root.appendingPathComponent("discovery")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        for (filename, name) in [("state_9.sqlite", "Older"), ("state_10.sqlite", "Newest"),
                                 ("state_999.sqlite.bak", "Backup"), ("state_bad.sqlite", "Invalid") ] {
            let database = try Database(directory.appendingPathComponent(filename))
            try database.createTable()
            try database.insert(a, name)
        }
        let source = ThreadNames(directory: directory)
        try expect(source.read(sessionIDs: [a]).names[a] == "Newest", "Newest database must be selected numerically, not lexicographically")
        try expect(reader(directory.appendingPathComponent("state_9.sqlite")).read(sessionIDs: [a]).names[a] == "Older", "Exact injected database must override discovery")
        try fm.createSymbolicLink(at: directory.appendingPathComponent("state_11.sqlite"),
                                  withDestinationURL: directory.appendingPathComponent("state_9.sqlite"))
        try expect(source.read(sessionIDs: [a]).status == .unavailable, "Unsafe newest database must not silently fall back to stale older names")
    }

    private static func safeFailureModes(_ root: URL) throws {
        let absent = root.appendingPathComponent("not-created.sqlite")
        try expect(reader(absent).read(sessionIDs: [a]).status == .unavailable, "Missing database is unavailable")
        try expect(!fm.fileExists(atPath: absent.path), "Read-only open must not create a missing database")
        let schema = root.appendingPathComponent("unsupported.sqlite")
        let database = try Database(schema)
        try database.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT)")
        let before = try Data(contentsOf: schema)
        let incompatible = reader(schema).read(sessionIDs: [a])
        try expect(incompatible.status == .incompatible && incompatible.names.isEmpty, "Missing name column must use graceful fallback without reading title")
        try expect(try Data(contentsOf: schema) == before, "Incompatible schema must not be migrated")
        let link = root.appendingPathComponent("linked.sqlite")
        try fm.createSymbolicLink(at: link, withDestinationURL: schema)
        try expect(reader(link).read(sessionIDs: [a]).status == .unavailable, "Database symlink must be refused")
        let directory = root.appendingPathComponent("directory.sqlite")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try expect(reader(directory).read(sessionIDs: [a]).status == .unavailable, "Database directory must be refused")
        let fifo = root.appendingPathComponent("fifo.sqlite")
        try expect(mkfifo(fifo.path, mode_t(0o600)) == 0, "FIFO fixture should be created")
        try expect(reader(fifo).read(sessionIDs: [a]).status == .unavailable, "FIFO must fail without blocking")
        let corrupt = root.appendingPathComponent("corrupt.sqlite")
        try Data("private-malformed-database-content".utf8).write(to: corrupt)
        let corrupted = reader(corrupt).read(sessionIDs: [a])
        try expect(corrupted.status == .incompatible && !corrupted.detail.contains("private"), "Malformed header must fail without exposing contents")
        try database.execute("BEGIN EXCLUSIVE")
        let start = Date()
        let busy = reader(schema).read(sessionIDs: [a])
        try expect(busy.status == .failed, "Busy database must fail gracefully")
        try expect(Date().timeIntervalSince(start) < 1, "Busy timeout must remain short")
        try database.execute("ROLLBACK")
    }

    private static func liveWAL(_ root: URL) throws {
        let url = root.appendingPathComponent("live.sqlite")
        var database: Database? = try Database(url)
        try database!.execute("PRAGMA journal_mode=WAL")
        try database!.createTable()
        try database!.insert(a, "Before rename")
        let source = reader(url)
        let beforeMain = try Data(contentsOf: url)
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let beforeWAL = try Data(contentsOf: walURL)
        try expect(source.read(sessionIDs: [a]).names[a] == "Before rename", "Live WAL names must be visible")
        try expect(try Data(contentsOf: url) == beforeMain && Data(contentsOf: walURL) == beforeWAL,
                   "Reader must leave database and WAL content unchanged")
        try database!.execute("UPDATE threads SET name='After rename'")
        try expect(source.read(sessionIDs: [a]).names[a] == "After rename", "Repeated reads must observe new WAL commits without immutable snapshots")
        database = nil
        // macOS may retain empty sidecars after close. Copy only the checkpointed
        // main fixture to model a clean WAL database with no coordination files.
        let cleanURL = root.appendingPathComponent("clean-wal.sqlite")
        try fm.copyItem(at: url, to: cleanURL)
        let files = try fm.contentsOfDirectory(atPath: root.path).sorted()
        try expect(reader(cleanURL).read(sessionIDs: [a]).status == .unavailable, "Clean WAL database without sidecars must wait for Codex instead of creating files")
        try expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == files, "Unavailable WAL read must create no sidecars")
    }

    private final class Database {
        let handle: OpaquePointer
        init(_ url: URL) throws {
            var opened: OpaquePointer?
            guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                  let opened else { throw Failure(message: "Cannot create SQLite fixture") }
            handle = opened
        }
        deinit { sqlite3_close(handle) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: "Fixture SQL failed") }
        }
        func createTable() throws {
            try execute("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, first_user_message TEXT)")
        }
        func insert(_ id: String, _ name: String?, title: String = "private-title") throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO threads (id,name,title,first_user_message) VALUES (?,?,?,'private-message')", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw Failure(message: "Cannot prepare fixture insert") }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, id, -1, transient)
            if let name {
                let bytes = Array(name.utf8) + [0]
                bytes.withUnsafeBufferPointer { buffer in
                    _ = sqlite3_bind_text(statement, 2, UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self), Int32(bytes.count - 1), transient)
                }
            } else { sqlite3_bind_null(statement, 2) }
            sqlite3_bind_text(statement, 3, title, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(message: "Fixture insert failed") }
        }
    }

    private struct Failure: Error { let message: String }
}
