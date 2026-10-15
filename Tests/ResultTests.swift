import Foundation
@main struct ResultTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.md")
        try Data("demo".utf8).write(to: file)
        func marker(_ object: [String: Any]) -> String {
            ": codex-notch:result " + (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
        }
        func parse(_ command: String) -> TurnResult? { ResultSignal.parse(command: command, sessionID: "session", turnID: "turn") }
        let command = marker(["path": file.path, "checks": "passed"])
        assert(parse(command)?.path == file.path)
        assert(parse(command)?.checks == .passed)
        assert(parse(marker(["checks": "notRun"]))?.path == nil)
        assert(parse(marker(["checks": "failed"]))?.checks == .failed)
        assert(parse(command + "\n") == nil)
        assert(parse(command + "; echo hidden") == nil)
        assert(parse("echo " + command) == nil)
        assert(parse(marker(["path": file.path, "checks": "passed", "command": "oops"])) == nil)
        assert(parse(marker(["path": "/missing/report.md", "checks": "passed"])) == nil)
        assert(parse(marker(["checks": "success"])) == nil)
        let script = directory.appendingPathComponent("run.command")
        try Data("echo oops".utf8).write(to: script)
        assert(ResultSignal.safePath(script.path) == nil)
        let link = directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        assert(ResultSignal.safePath(link.path) == nil)
        print("Result signals: 12 checks passed")
    }
}
