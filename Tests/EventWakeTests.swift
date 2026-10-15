import Foundation

@main
struct EventWakeTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-event-wake-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spool = EventSpool(directory: folder)
        var batches: [[CompanionEvent]] = []
        let watcher = EventWake(directory: folder) { batches.append(spool.drain()) }
        watcher.start()
        precondition(watcher.isWatching)
        func run(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        try Data("metadata".utf8).write(to: folder.appendingPathComponent("statistics.json"), options: .atomic)
        run(0.2)
        precondition(batches.isEmpty, "Metadata writes cannot trigger a self-refresh loop")
        let event = CompanionEvent(event: "UserPromptSubmit", sessionID: "00112233-4455-6677-8899-aabbccddeeff",
            turnID: "test", toolName: nil, toolUseID: nil, timestamp: Date())
        try spool.append(event); try spool.append(event)
        run(0.4)
        precondition(batches.count == 1 && batches[0].count == 2, "Bursts coalesce without dropping events")
        run(0.2)
        precondition(batches.count == 1, "Draining does not loop")
        watcher.stop()
        precondition(!watcher.isWatching)
        try spool.append(event)
        run(0.2)
        precondition(batches.count == 1, "Stopped watcher is quiet")
        watcher.start()
        try spool.append(event)
        run(0.4)
        precondition(batches.count == 2 && batches[1].count == 2, "Restart preserves queued events")
        watcher.stop()
        print("PASS: Event-driven spool, metadata isolation, coalescing and restart")
    }
}
