import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads explicitly assigned UI names only. Never falls back to generated titles or chat content.
struct ThreadNames {
    enum Status: String { case available, unavailable, incompatible, failed }
    struct Result {
        let names: [String: String]
        let status: Status
        let detail: String
    }

    static var defaultDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        for key in ["CODEX_SQLITE_HOME", "CODEX_HOME"] {
            if let path = environment[key], !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private let directory: URL
    private let databaseURL: URL?
    private static let maxIDs = 512

    init(directory: URL = ThreadNames.defaultDirectory, databaseURL: URL? = nil) {
        self.directory = directory
        if let databaseURL {
            self.databaseURL = databaseURL
        } else if let override = ProcessInfo.processInfo.environment["CODEX_NOTCH_STATE_DB"], !override.isEmpty {
            self.databaseURL = URL(fileURLWithPath: override)
        } else {
            self.databaseURL = nil
        }
    }

    func read(sessionIDs: [String]) -> Result {
        let ids = Array(Set(sessionIDs.prefix(Self.maxIDs).compactMap(Self.canonicalID))).sorted()
        guard let url = databaseURL ?? discoveredDatabase(), url.isFileURL, url.path.hasPrefix("/") else {
            return result(.unavailable, "Локальная база имён Codex пока недоступна.")
        }
        switch inspectDatabase(url) {
        case .ready: break
        case .unavailable:
            return result(.unavailable, "Локальная база имён недоступна или её путь нельзя безопасно открыть.")
        case .incompatible:
            return result(.incompatible, "Формат локальной базы Codex не поддерживает чтение имён.")
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        let opened = sqlite3_open_v2(url.path, &database, flags, nil)
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return result(opened == SQLITE_CANTOPEN ? .unavailable : .failed,
                          "Не удалось открыть локальную базу имён только для чтения.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = ids.isEmpty ? "SELECT id, name FROM threads WHERE 0"
            : "SELECT id, name FROM threads WHERE id IN (" + placeholders + ")"
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return result(prepared == SQLITE_ERROR ? .incompatible : .failed,
                          prepared == SQLITE_ERROR ? "В этой версии Codex отдельное поле имени чата недоступно."
                              : "Не удалось прочитать имена. Можно повторить позже.")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, id) in ids.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), id, -1, transient) == SQLITE_OK else {
                return result(.failed, "Не удалось подготовить чтение имён известных чатов.")
            }
        }
        let allowed = Set(ids)
        var names: [String: String] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                return result(.failed, "База имён временно недоступна. Можно повторить позже.")
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  let idBytes = sqlite3_column_text(statement, 0), sqlite3_column_bytes(statement, 0) == 36,
                  let nameBytes = sqlite3_column_text(statement, 1) else { continue }
            let id = String(decoding: UnsafeBufferPointer(start: idBytes, count: 36), as: UTF8.self)
            guard allowed.contains(id) else { continue }
            // Bound temporary decoding too; no arbitrary-length database value enters the UI.
            let byteCount = min(8192, Int(sqlite3_column_bytes(statement, 1)))
            let rawName = String(decoding: UnsafeBufferPointer(start: nameBytes, count: byteCount), as: UTF8.self)
            let scalars = rawName.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
            }
            let name = String(String(String.UnicodeScalarView(scalars)).prefix(200))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names[id] = name }
        }
        return Result(names: names, status: .available,
                      detail: "Имена доступны локально. Прочитаны только ID и заданные имена известных чатов.")
    }

    private func result(_ status: Status, _ detail: String) -> Result {
        Result(names: [:], status: status, detail: detail)
    }

    private static func canonicalID(_ value: String) -> String? {
        guard value.utf8.count == 36, let id = UUID(uuidString: value),
              id.uuidString.lowercased() == value.lowercased() else { return nil }
        return id.uuidString.lowercased()
    }

    private func discoveredDatabase() -> URL? {
        guard directory.isFileURL,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let candidates: [(UInt64, URL)] = files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            let version = String(name.dropFirst(6).dropLast(7))
            guard !version.isEmpty, version.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = UInt64(version) else { return nil }
            return (number, url)
        }
        return candidates.sorted { left, right in
            left.0 == right.0 ? left.1.lastPathComponent > right.1.lastPathComponent : left.0 > right.0
        }.first?.1
    }

    private enum Inspection { case ready, unavailable, incompatible }

    private func inspectDatabase(_ url: URL) -> Inspection {
        // Check the file descriptor before reading so special files cannot block diagnostics.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd != -1 else { return .unavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return .unavailable }
        guard let header = try? file.read(upToCount: 100), header.count == 100,
              header.prefix(16) == Data("SQLite format 3\0".utf8) else { return .incompatible }
        // A live WAL database already has both sidecars. Without them, a read-only
        // SQLite connection may create coordination files; wait for Codex instead.
        if header[18] == 2 || header[19] == 2 {
            for suffix in ["-wal", "-shm"] {
                var sidecar = stat()
                guard lstat(url.path + suffix, &sidecar) == 0,
                      sidecar.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return .unavailable }
            }
        }
        return .ready
    }
}
