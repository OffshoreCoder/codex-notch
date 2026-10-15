import Foundation

@main
struct HookConfigurationTests {
    private static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                                 "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
    private static let marker = " --hook --codex-notch"
    private static var checks = 0

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexNotchHooksTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try previewDoesNotWrite(root)
        try mergeReplaceDisconnect(root)
        try quotedExecutableRunsLiterally(root)
        try invalidFilesRemainUntouched(root)
        try filePermissionsAndSymlinks(root)
        print("PASS: HookConfiguration (\(checks) checks)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw TestFailure(message: message) }
    }

    private static func previewDoesNotWrite(_ root: URL) throws {
        let directory = root.appendingPathComponent("preview/not-created")
        let url = directory.appendingPathComponent("hooks.json")
        let data = try HookConfiguration.preview(at: url, executableURL: URL(fileURLWithPath: "/Applications/CodexNotch.app/Contents/MacOS/CodexNotch"))
        let hooks = try dictionary(data)["hooks"] as! [String: Any]
        try expect(hooks.count == events.count, "Preview should contain all supported events")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("preview").path), "Preview must not create parent directories")
        _ = try HookConfiguration.disconnect(at: url)
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("preview").path), "Disconnect on a missing file must not create directories")
        for event in events {
            let managed = handlers(hooks, event).filter(isManaged)
            try expect(managed.count == 1, "Expected one managed handler for \(event)")
            try expect((managed[0]["timeout"] as? Int) == 1, "Hooks must have a one-second timeout")
            try expect(managed[0]["async"] == nil, "Hooks must not be asynchronous")
        }
    }

    private static func mergeReplaceDisconnect(_ root: URL) throws {
        let directory = root.appendingPathComponent("merge")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("hooks.json")
        let oldHandler: [String: Any] = ["type": "command", "command": "'/old/app'" + marker, "timeout": 1]
        let unrelated: [String: Any] = ["type": "command", "command": "echo user-owned", "timeout": 15, "async": true]
        let markerElsewhere: [String: Any] = ["type": "command", "command": "echo ' --hook --codex-notch' suffix"]
        let initial: [String: Any] = [
            "notify": ["existing-notifier", "arg with spaces"],
            "metadata": ["keep": true, "number": 42],
            "hooks": [
                "PermissionRequest": [["matcher": "Read|Write", "description": "User group", "hooks": [oldHandler, unrelated]]],
                "PreToolUse": [["matcher": "*", "hooks": [markerElsewhere]]],
                "FutureEvent": [["hooks": [unrelated]]]
            ]
        ]
        var original = try JSONSerialization.data(withJSONObject: initial, options: [.prettyPrinted])
        original.append(contentsOf: [0x0A, 0x20, 0x0A])
        try original.write(to: url)
        let executable = URL(fileURLWithPath: "/Applications/Companion app's $literal`path`.app/Contents/MacOS/CodexNotch")
        _ = try HookConfiguration.connect(at: url, executableURL: executable)
        let saved = try Data(contentsOf: url)
        let merged = try dictionary(saved)
        try expect(NSDictionary(dictionary: merged["metadata"] as! [String: Any]).isEqual(to: initial["metadata"] as! [String: Any]), "Top-level metadata must survive")
        try expect((merged["notify"] as? [String]) == initial["notify"] as? [String], "Existing notify must remain untouched")
        let hooks = merged["hooks"] as! [String: Any]
        let permissionGroups = hooks["PermissionRequest"] as! [[String: Any]]
        try expect(permissionGroups[0]["matcher"] as? String == "Read|Write", "Mixed group matcher must survive")
        try expect(permissionGroups[0]["description"] as? String == "User group", "Mixed group metadata must survive")
        try expect(NSDictionary(dictionary: (permissionGroups[0]["hooks"] as! [[String: Any]])[0]).isEqual(to: unrelated), "Unrelated mixed-group handler must survive exactly")
        try expect(handlers(hooks, "PreToolUse").contains { $0["command"] as? String == markerElsewhere["command"] as? String }, "Only a trailing exact marker identifies a managed command")
        try expect(handlers(hooks, "FutureEvent").count == 1, "Unknown event handlers must survive")
        for event in events {
            try expect(handlers(hooks, event).filter(isManaged).count == 1, "Merge must leave exactly one own handler per event")
        }
        let backups = try backupFiles(directory)
        try expect(backups.count == 1, "Connect should make one dated backup")
        try expect(try Data(contentsOf: backups[0]) == original, "Backup must contain exact original bytes")
        try expect(backups[0].lastPathComponent.range(of: #"hooks\.json\.codex-notch-\d{8}T\d{6}\.\d{3}Z-"#, options: .regularExpression) != nil, "Backup filename must contain its UTC date")
        _ = try HookConfiguration.connect(at: url, executableURL: executable)
        try expect(try Data(contentsOf: url) == saved, "Repeated connect must not rewrite the file")
        try expect(try backupFiles(directory).count == 1, "Repeated connect must not make extra backups")

        let replacement = URL(fileURLWithPath: "/Applications/New CodexNotch.app/Contents/MacOS/CodexNotch")
        _ = try HookConfiguration.connect(at: url, executableURL: replacement)
        let replaced = try dictionary(Data(contentsOf: url))["hooks"] as! [String: Any]
        for event in events {
            let own = handlers(replaced, event).filter(isManaged)
            try expect(own.count == 1 && own[0]["command"] as? String == "'/Applications/New CodexNotch.app/Contents/MacOS/CodexNotch'" + marker, "Changing app path should replace only owned handlers")
        }
        _ = try HookConfiguration.disconnect(at: url)
        let disconnected = try dictionary(Data(contentsOf: url))
        let remaining = disconnected["hooks"] as! [String: Any]
        try expect(events.allSatisfy { handlers(remaining, $0).allSatisfy { !isManaged($0) } }, "Disconnect must remove every owned handler")
        try expect(handlers(remaining, "PermissionRequest").count == 1, "Disconnect must preserve mixed-group unrelated handler")
        try expect(handlers(remaining, "PreToolUse").count == 1, "Disconnect must preserve unrelated group")
        try expect(handlers(remaining, "FutureEvent").count == 1, "Disconnect must preserve unknown events")
        try expect(disconnected["notify"] as? [String] == initial["notify"] as? [String], "Disconnect must preserve notify")
        let beforeRepeat = try Data(contentsOf: url)
        let backupCount = try backupFiles(directory).count
        _ = try HookConfiguration.disconnect(at: url)
        try expect(try Data(contentsOf: url) == beforeRepeat, "Repeated disconnect must not rewrite the file")
        try expect(try backupFiles(directory).count == backupCount, "Repeated disconnect must not make a backup")
    }

    private static func quotedExecutableRunsLiterally(_ root: URL) throws {
        let directory = root.appendingPathComponent("quotes ' $ ` literal")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("hook executable's file")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let data = try HookConfiguration.preview(at: root.appendingPathComponent("quote-hooks.json"), executableURL: executable)
        let hooks = try dictionary(data)["hooks"] as! [String: Any]
        let command = handlers(hooks, "Stop")[0]["command"] as! String
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "Quoted executable must execute successfully")
        try expect(String(data: output, encoding: .utf8) == "--hook\n--codex-notch\n", "Shell must pass exactly the two literal marker arguments")
    }

    private static func invalidFilesRemainUntouched(_ root: URL) throws {
        for (index, invalid) in ["{ invalid json", "[]", #"{"hooks":{"Stop":"bad shape"}}"#, #"{"hooks":{"Stop":[{"matcher":"*"}]}}"#].enumerated() {
            let directory = root.appendingPathComponent("invalid-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let url = directory.appendingPathComponent("hooks.json")
            let bytes = Data(invalid.utf8)
            try bytes.write(to: url)
            do {
                _ = try HookConfiguration.connect(at: url, executableURL: URL(fileURLWithPath: "/app"))
                throw TestFailure(message: "Invalid input must fail")
            } catch is TestFailure { throw TestFailure(message: "Invalid input unexpectedly succeeded") }
            catch { checks += 1 }
            try expect(try Data(contentsOf: url) == bytes, "Invalid file must stay byte-for-byte unchanged")
            try expect(try backupFiles(directory).isEmpty, "Invalid file must not create backups")
        }
    }

    private static func filePermissionsAndSymlinks(_ root: URL) throws {
        let directory = root.appendingPathComponent("permissions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o750])
        let url = directory.appendingPathComponent("hooks.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        _ = try HookConfiguration.connect(at: url, executableURL: URL(fileURLWithPath: "/app"))
        try expect(try permissions(url) == 0o600, "New config must have owner-only permissions")
        try expect(try permissions(directory) == 0o750, "Existing parent permissions must not change")
        try expect(try backupFiles(directory).allSatisfy { try permissions($0) == 0o600 }, "Backups must have owner-only permissions")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        _ = try HookConfiguration.disconnect(at: url)
        try expect(try permissions(url) == 0o400, "Existing stricter permissions must not be widened")
        let target = directory.appendingPathComponent("real.json")
        let link = directory.appendingPathComponent("linked.json")
        let original = Data("{\"keep\":true}".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try HookConfiguration.connect(at: link, executableURL: URL(fileURLWithPath: "/app"))
            throw TestFailure(message: "Symlink config should fail safely")
        } catch is TestFailure { throw TestFailure(message: "Symlink config unexpectedly succeeded") }
        catch { checks += 1 }
        try expect(try Data(contentsOf: target) == original, "Symlink target must remain unchanged")
        try expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path, "Symlink itself must remain unchanged")
    }

    private static func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    private static func backupFiles(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "bak" }
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private static func handlers(_ hooks: [String: Any], _ event: String) -> [[String: Any]] {
        (hooks[event] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    private static func isManaged(_ handler: [String: Any]) -> Bool {
        handler["type"] as? String == "command" && (handler["command"] as? String)?.hasSuffix(marker) == true
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
