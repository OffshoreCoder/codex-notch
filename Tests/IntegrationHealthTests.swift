import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct IntegrationHealthTests {
    private static var checks = 0
    private static let fm = FileManager.default

    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("CodexNotchHealthTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        try missingSignalsAreNotFailures(root)
        try roundtripPreservesUserFiles(root)
        try configurationProblems(root)
        try symlinksAndNonRegularFiles(root)
        print("PASS: IntegrationHealth (\(checks) checks)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw TestFailure(message: message) }
    }

    private static func makeFixture(_ root: URL, _ name: String) throws -> (URL, URL, URL, URL) {
        let base = root.appendingPathComponent(name)
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let executable = base.appendingPathComponent("App's $literal` executable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (base, base.appendingPathComponent("hooks.json"), executable, base.appendingPathComponent("runtime"))
    }

    private static func status(_ id: String, _ report: IntegrationHealth.Report) -> IntegrationHealth.Status? {
        report.checks.first { $0.id == id }?.status
    }

    private static func missingSignalsAreNotFailures(_ root: URL) throws {
        let (base, config, executable, spool) = try makeFixture(root, "missing")
        let report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(!report.hasFailures, "No config or events must not be called a proven failure")
        try expect(status("hooks", report) == .warning, "Missing config should need setup")
        try expect(status("spool", report) == .warning, "Missing spool should remain unconfirmed")
        try expect(status("hook-trust", report) == .unknown, "Trust must never be claimed by local checks")
        try expect(status("self-test", report) == .unknown, "Read-only diagnostics must not claim a self-test")
        try expect(try fm.contentsOfDirectory(atPath: base.path).count == 1, "Read-only diagnostics must create no files")
        let tested = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool, runSelfTest: true)
        try expect(status("self-test", tested) == .ok, "Explicit self-test should create a missing runtime directory")
        try expect(status("hook-trust", tested) == .unknown, "Self-test must not claim hook trust")
        try expect(try fm.contentsOfDirectory(atPath: spool.path).isEmpty, "Self-test must clean all temporary files")
        let permissions = (try fm.attributesOfItem(atPath: spool.path)[.posixPermissions] as! NSNumber).intValue
        try expect(permissions == 0o700, "Self-test runtime directory must be private")
    }

    private static func roundtripPreservesUserFiles(_ root: URL) throws {
        let (base, config, executable, spool) = try makeFixture(root, "roundtrip")
        _ = try HookConfiguration.connect(at: config, executableURL: executable)
        try fm.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let event = spool.appendingPathComponent("0000000001.event")
        let sentinel = Data("live event left untouched".utf8)
        try sentinel.write(to: event)
        let configBytes = try Data(contentsOf: config)
        let baseFiles = try fm.contentsOfDirectory(atPath: base.path).sorted()
        let report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool, runSelfTest: true)
        try expect(!report.hasFailures, "Valid fixture must pass local checks")
        try expect(status("hooks", report) == .ok, "All current executable hooks should be recognized")
        try expect(status("self-test", report) == .ok, "Self-test must survive literal shell characters in paths")
        try expect(try Data(contentsOf: config) == configBytes, "Health must leave config bytes unchanged")
        try expect(try Data(contentsOf: event) == sentinel, "Self-test must not drain, parse, or alter live queue")
        try expect(try fm.contentsOfDirectory(atPath: spool.path) == [event.lastPathComponent], "Self-test must clean its subdirectory")
        try expect(try fm.contentsOfDirectory(atPath: base.path).sorted() == baseFiles, "Diagnostics must not create config backups")
        try fm.setAttributes([.posixPermissions: 0o750], ofItemAtPath: spool.path)
        let permissionReport = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(status("spool", permissionReport) == .warning, "Permissions wider than owner-only should be visible")
        try expect((try fm.attributesOfItem(atPath: spool.path)[.posixPermissions] as! NSNumber).intValue == 0o750,
                   "Read-only diagnostics must not change directory permissions")
    }

    private static func configurationProblems(_ root: URL) throws {
        let (_, config, executable, spool) = try makeFixture(root, "config")
        _ = try HookConfiguration.connect(at: config, executableURL: executable)
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        var hooks = document["hooks"] as! [String: Any]
        var groups = hooks["Stop"] as! [[String: Any]]
        groups[0]["matcher"] = "some-limited-match"
        hooks["Stop"] = groups
        document["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: document).write(to: config)
        var report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(status("hooks", report) == .warning, "Filtered managed hooks are not sufficient")
        try expect(report.checks.first { $0.id == "hooks" }?.detail.contains("Stop") == true, "Incomplete event should be named")
        groups[0].removeValue(forKey: "matcher")
        groups.append(groups[0])
        hooks["Stop"] = groups
        document["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: document).write(to: config)
        report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(status("hooks", report) == .warning, "Duplicate handlers should be diagnosed")
        _ = try HookConfiguration.connect(at: config, executableURL: URL(fileURLWithPath: "/old/nonexistent/app"))
        report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(status("hooks", report) == .warning, "Old executable paths should not be considered healthy")
        let invalidDocuments = ["{broken", "[]", #"{"hooks":[]}"#, #"{"hooks":{"Stop":"bad"}}"#,
                                #"{"hooks":{"Stop":[{"matcher":"*"}]}}"#]
        for invalid in invalidDocuments {
            let bytes = Data(invalid.utf8)
            try bytes.write(to: config)
            report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
            try expect(status("hooks", report) == .failure, "Malformed config must be a concrete failure")
            try expect(try Data(contentsOf: config) == bytes, "Invalid config must remain unchanged")
        }
        try Data(repeating: 0x20, count: 1_048_577).write(to: config)
        report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(status("hooks", report) == .failure, "Oversized config should be rejected before reading")
    }

    private static func symlinksAndNonRegularFiles(_ root: URL) throws {
        let (base, config, executable, spool) = try makeFixture(root, "symlinks")
        let target = base.appendingPathComponent("target.json")
        let bytes = Data("{}".utf8)
        try bytes.write(to: target)
        try fm.createSymbolicLink(at: config, withDestinationURL: target)
        var report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(status("hooks", report) == .failure, "Config symlink must be rejected")
        try expect(try Data(contentsOf: target) == bytes, "Config symlink target must remain unchanged")
        try fm.removeItem(at: config)
        try fm.createDirectory(at: config, withIntermediateDirectories: false)
        report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(status("hooks", report) == .failure, "Config directory must be rejected")
        try fm.removeItem(at: config)
        try expect(mkfifo(config.path, mode_t(0o600)) == 0, "Fixture FIFO should be created")
        report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(status("hooks", report) == .failure, "FIFO config must fail without blocking")
        try fm.removeItem(at: config)
        let targetDirectory = base.appendingPathComponent("unrelated")
        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: spool, withDestinationURL: targetDirectory)
        report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool, runSelfTest: true)
        try expect(status("spool", report) == .failure, "Runtime symlink must be rejected")
        try expect(status("self-test", report) == .failure, "Self-test must not follow runtime symlinks")
        try expect(try fm.contentsOfDirectory(atPath: targetDirectory.path).isEmpty, "Self-test must not write through runtime symlinks")
        let executableLink = base.appendingPathComponent("app-link")
        try fm.createSymbolicLink(at: executableLink, withDestinationURL: executable)
        report = IntegrationHealth.check(hooksURL: config, executableURL: executableLink, spoolDirectory: spool)
        try expect(status("executable", report) == .failure, "Executable symlinks should not be reported as a verified regular file")
        report = IntegrationHealth.check(hooksURL: config, executableURL: base.appendingPathComponent("missing"), spoolDirectory: spool)
        try expect(status("executable", report) == .failure, "Missing executable is a concrete failure")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        report = IntegrationHealth.check(hooksURL: config, executableURL: executable, spoolDirectory: spool)
        try expect(status("executable", report) == .failure, "Nonexecutable file is a concrete failure")
    }

    private struct TestFailure: Error { let message: String }
}
