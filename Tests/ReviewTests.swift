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
  print("Review workflow: 9 checks passed")
 }
}
