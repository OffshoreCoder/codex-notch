import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Adds only this app's command hooks; all other JSON is kept intact.
enum HookConfiguration {
    private static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "Stop", "Interrupt", "SessionEnd"
    ]
    private static let commandMarker = " --hook --codex-notch"

    static func connect(at hooksURL: URL, executableURL: URL) throws -> String {
        let original = try snapshot(at: hooksURL)
        let document = try decode(original.data)
        let updated = try connected(document, executableURL: executableURL)
        if original.data != nil, equal(document, updated) {
            return "Codex hooks are already connected."
        }
        let backup = try save(encode(updated), at: hooksURL, replacing: original)
        return backup.map { "Codex hooks connected. Backup: \($0.lastPathComponent)" }
            ?? "Codex hooks connected."
    }

    static func disconnect(at hooksURL: URL) throws -> String {
        let original = try snapshot(at: hooksURL)
        let document = try decode(original.data)
        let updated = try removingManagedHooks(from: document)
        guard original.data != nil, !equal(document, updated) else {
            return "No CodexNotch hooks to remove."
        }
        let backup = try save(encode(updated), at: hooksURL, replacing: original)
        return backup.map { "Codex hooks disconnected. Backup: \($0.lastPathComponent)" }
            ?? "Codex hooks disconnected."
    }

    /// Produces the proposed JSON without creating directories, backups, or files.
    static func preview(at hooksURL: URL, executableURL: URL) throws -> Data {
        try encode(connected(decode(snapshot(at: hooksURL).data), executableURL: executableURL))
    }

    private static func connected(_ document: [String: Any], executableURL: URL) throws -> [String: Any] {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              !executableURL.path.contains("\0") else {
            throw ConfigurationError("The app executable must have an absolute local file path.")
        }
        var updated = try removingManagedHooks(from: document)
        var hooks = updated["hooks"] as? [String: Any] ?? [:]
        // POSIX single quotes prevent spaces, apostrophes, $, and backticks in a path
        // from being interpreted by the shell.
        let quotedPath = "'" + executableURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let handler: [String: Any] = [
            "type": "command", "command": quotedPath + commandMarker, "timeout": 1
        ]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [handler]])
            hooks[event] = groups
        }
        updated["hooks"] = hooks
        return updated
    }

    private static func removingManagedHooks(from document: [String: Any]) throws -> [String: Any] {
        guard let rawHooks = document["hooks"] else { return document }
        guard var hooks = rawHooks as? [String: Any] else {
            throw ConfigurationError("The hooks field in hooks.json must be an object.")
        }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                if events.contains(event) {
                    throw ConfigurationError("The \(event) hooks must be an array of hook groups.")
                }
                continue
            }
            var remainingGroups: [[String: Any]] = []
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    if events.contains(event) {
                        throw ConfigurationError("A \(event) group must contain a hooks array.")
                    }
                    remainingGroups.append(group)
                    continue
                }
                let remaining = handlers.filter { !isManaged($0) }
                if remaining.count == handlers.count {
                    remainingGroups.append(group)
                } else if !remaining.isEmpty {
                    var preserved = group
                    preserved["hooks"] = remaining
                    remainingGroups.append(preserved)
                }
            }
            // Keep the event key, including pre-existing empty arrays. This avoids
            // deleting a user's event-level structure on disconnect.
            hooks[event] = remainingGroups
        }
        var updated = document
        updated["hooks"] = hooks
        return updated
    }

    private static func isManaged(_ handler: [String: Any]) -> Bool {
        handler["type"] as? String == "command"
            && (handler["command"] as? String)?.hasSuffix(commandMarker) == true
    }

    private static func decode(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        do {
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigurationError("hooks.json must contain a JSON object.")
            }
            return document
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError("hooks.json contains invalid JSON; it was left unchanged. \(error.localizedDescription)")
        }
    }

    private static func encode(_ document: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    private struct Snapshot: Equatable {
        var data: Data?
        var mode: mode_t = 0o600
        var device: UInt64 = 0
        var inode: UInt64 = 0
    }

    private static func snapshot(at url: URL) throws -> Snapshot {
        guard url.isFileURL else { throw ConfigurationError("hooks.json must be a local file.") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd == -1 {
            if errno == ENOENT { return Snapshot(data: nil) }
            if errno == ELOOP {
                throw ConfigurationError("hooks.json is a symbolic link. Choose its real file before connecting; the link and target were left unchanged.")
            }
            throw systemError("Cannot read hooks.json")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError("Cannot inspect hooks.json") }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ConfigurationError("hooks.json must be a regular file.")
        }
        return Snapshot(data: try file.readToEnd() ?? Data(), mode: info.st_mode & 0o777,
                        device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func save(_ data: Data, at url: URL, replacing original: Snapshot) throws -> URL? {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)
        guard try snapshot(at: url) == original else {
            throw ConfigurationError("hooks.json changed while preparing the update. Retry to merge the latest version.")
        }
        // Tighten access without widening the original file's owner permissions.
        let mode = original.data == nil ? mode_t(0o600) : original.mode & 0o600
        var backupURL: URL?
        if let originalData = original.data {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
            let name = url.lastPathComponent + ".codex-notch-" + formatter.string(from: Date())
                + "-" + UUID().uuidString.prefix(8) + ".bak"
            let backup = directory.appendingPathComponent(name)
            try writeNewFile(originalData, at: backup, mode: mode)
            backupURL = backup
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).codex-notch-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeNewFile(data, at: temporary, mode: mode)
        guard try snapshot(at: url) == original else {
            throw ConfigurationError("hooks.json changed before saving. The latest file was left unchanged; retry the update.")
        }
        guard rename(temporary.path, url.path) == 0 else { throw systemError("Cannot replace hooks.json") }
        return backupURL
    }

    private static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ConfigurationError("The hooks.json parent must be a directory.") }
            return
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw ConfigurationError("Cannot create the hooks.json directory.") }
        try ensureDirectory(parent)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            // Another process may have created it in the meantime. Never chmod it.
            var nowDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &nowDirectory), nowDirectory.boolValue else {
                throw error
            }
        }
    }

    private static func writeNewFile(_ data: Data, at url: URL, mode: mode_t) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd != -1 else { throw systemError("Cannot create \(url.lastPathComponent)") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var succeeded = false
        defer {
            try? file.close()
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        try file.write(contentsOf: data)
        guard fchmod(fd, mode) == 0 else { throw systemError("Cannot protect \(url.lastPathComponent)") }
        guard fsync(fd) == 0 else { throw systemError("Cannot flush \(url.lastPathComponent)") }
        succeeded = true
    }

    private static func systemError(_ operation: String) -> ConfigurationError {
        ConfigurationError("\(operation): \(String(cString: strerror(errno)))")
    }

    private struct ConfigurationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
