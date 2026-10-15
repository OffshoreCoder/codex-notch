import Foundation
@main struct ArchiveTests {
 static func main() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let store = LocalStore(directory: dir)
  let now = Date()
  let chat = ChatSummary(id: "s", turnID: "t", state: .finished, startedAt: now, updatedAt: now)
  store.remember([chat])
  store.archive("s", now: now)
  assert(store.data.archivedChats["s"] == now)
  assert(LocalStore(directory: dir).data.archivedChats["s"] == now)
  let start = CompanionEvent(event: "SessionStart", sessionID: "s", turnID: nil, toolName: nil, toolUseID: nil, timestamp: now.addingTimeInterval(1))
  store.restoreForEvent(start, accepted: true)
  assert(store.data.archivedChats["s"] != nil)
  let prompt = CompanionEvent(event: "UserPromptSubmit", sessionID: "s", turnID: "new", toolName: nil, toolUseID: nil, timestamp: now.addingTimeInterval(2))
  store.restoreForEvent(prompt, accepted: false)
  assert(store.data.archivedChats["s"] != nil)
  store.restoreForEvent(prompt, accepted: true)
  assert(store.data.archivedChats.isEmpty)
  store.record(CompletedTurn(sessionID: "s", turnID: "t", startedAt: now, finishedAt: now))
  store.archive("s")
  assert(store.data.archivedChats.isEmpty)
  store.acknowledgeChat("s")
  store.archive("s")
  assert(!store.data.archivedChats.isEmpty)
  store.record(CompletedTurn(sessionID: "s", turnID: "t", startedAt: now, finishedAt: now))
  assert(!store.data.archivedChats.isEmpty)
  store.record(CompletedTurn(sessionID: "s", turnID: "new", startedAt: now, finishedAt: now))
  assert(store.data.archivedChats.isEmpty)
  print("Local archive: 9 checks passed")
 }
}
