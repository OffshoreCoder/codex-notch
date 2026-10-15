import Foundation
@main struct ReviewTests {
 static func main() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let store = LocalStore(directory: dir)
  let now = Date()
  let plain = CompletedTurn(sessionID: "a", turnID: "1", startedAt: nil, finishedAt: now)
  let review = CompletedTurn(sessionID: "b", turnID: "2", startedAt: nil, finishedAt: now)
  store.record(plain); store.record(review)
  store.update { $0.attention[review.id] = AttentionRequest(sessionID: "b", turnID: "2", kind: .review, requestedAt: now) }
  store.openChat("a")
  assert(!store.data.completions.contains(plain))
  store.openChat("b")
  assert(store.data.completions.contains(review) && store.data.reviewingIDs == [review.id])
  assert(LocalStore(directory: dir).data.reviewingIDs == [review.id])
  store.openChat("b")
  assert(store.data.reviewingIDs.count == 1)
  store.acknowledgeChat("b")
  assert(store.data.reviewingIDs.isEmpty && store.data.completions.isEmpty && store.data.attention.isEmpty)
  store.update { $0.results[review.id] = TurnResult(sessionID: "b", turnID: "2", path: nil, checks: .notRun, timestamp: now) }
  store.record(CompletedTurn(sessionID: "b", turnID: "next", startedAt: nil, finishedAt: now))
  store.markOpened(review.id)
  assert(store.data.reviewingIDs == [review.id])
  store.acknowledgeAll()
  assert(store.data.reviewingIDs.isEmpty)
  store.markOpened(review.id)
  assert(store.data.reviewingIDs.isEmpty)
  let restarted = LocalStore(directory: dir)
  restarted.markOpened(review.id)
  assert(restarted.data.reviewingIDs.isEmpty)
  try questionNavigation(in: dir.appendingPathComponent("questions"), now: now)
  print("PASS: review workflow and persistent unanswered-question navigation")
 }

 static func questionNavigation(in dir: URL, now: Date) throws {
  var store = LocalStore(directory: dir)
  func event(_ name: String, turn: String, delta: TimeInterval = 0) -> CompanionEvent {
   CompanionEvent(event: name, sessionID: "question-chat", turnID: turn, toolName: nil, toolUseID: nil,
    timestamp: now.addingTimeInterval(delta))
  }
  func ask(_ turn: String) {
   let chat = ChatSummary(id: "question-chat", turnID: turn, state: .working, startedAt: now, updatedAt: now)
   assert(store.receiveAttention(event("AttentionQuestion", turn: turn), current: chat))
  }
  ask("question-1")
  let firstKey = "question-chat|question-1"
  store.openChat("question-chat")
  assert(store.data.attention[firstKey]?.kind == .question)
  assert(store.data.reviewingIDs.isEmpty)
  store = LocalStore(directory: dir)
  assert(store.data.attention[firstKey]?.kind == .question)
  store.record(CompletedTurn(sessionID: "question-chat", turnID: "question-1", startedAt: now,
    finishedAt: now.addingTimeInterval(30)))
  store.openChat("question-chat")
  assert(store.data.completions.isEmpty)
  assert(store.data.attention[firstKey]?.kind == .question)
  store = LocalStore(directory: dir)
  store.markOpened(firstKey)
  assert(store.data.attention[firstKey]?.kind == .question)
  store.clearAttentionForLifecycle(event("UserPromptSubmit", turn: "question-2", delta: 40), accepted: false)
  assert(store.data.attention[firstKey]?.kind == .question)
  store.clearAttentionForLifecycle(event("UserPromptSubmit", turn: "question-2", delta: 40), accepted: true)
  assert(store.data.attention.isEmpty)
  ask("question-2")
  let current = ChatSummary(id: "question-chat", turnID: "question-2", state: .working, startedAt: now, updatedAt: now)
  _ = store.receiveAttention(event("AttentionClear", turn: "question-2", delta: 1), current: current)
  assert(store.data.attention.isEmpty)
  ask("question-3")
  store.clearAttentionForLifecycle(event("SessionEnd", turn: "question-3", delta: 2), accepted: true)
  assert(store.data.attention.isEmpty)
  ask("question-4")
  store.acknowledgeChat("question-chat")
  assert(store.data.attention.isEmpty)
  ask("question-5")
  store.acknowledge("question-chat|question-5")
  assert(store.data.attention.isEmpty)
  ask("question-6")
  store.acknowledgeAll()
  assert(store.data.attention.isEmpty)
 }
}
