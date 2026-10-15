import Foundation
@main struct ResultWorkflowTests {
 static func main() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let store = LocalStore(directory: dir)
  let now = Date()
  let chat = ChatSummary(id: "s", turnID: "t", state: .working, startedAt: now, updatedAt: now)
  let json = Data("{\"checks\":\"notRun\"}".utf8).base64EncodedString()
  let hook: [String: Any] = ["hook_event_name":"PostToolUse", "session_id":"s", "turn_id":"t", "tool_name":"exec_command", "tool_input":["cmd": ": codex-notch:result " + json], "last_assistant_message":"PRIVATE_SENTINEL"]
  let data = try JSONSerialization.data(withJSONObject: hook)
  let event = CompanionEvent.resultFromHook(data, now: now)!
  assert(store.receiveResult(event, current: chat))
  assert(!store.receiveResult(event, current: chat))
  assert(!store.receiveResult(event, current: nil))
  let wrong = ChatSummary(id: "s", turnID: "other", state: .working, startedAt: now, updatedAt: now)
  assert(!store.receiveResult(event, current: wrong))
  assert(store.data.results["s|t"]?.checks == .notRun)
  let encoded = try String(contentsOf: dir.appendingPathComponent("library.json"), encoding: .utf8)
  assert(!encoded.contains("PRIVATE_SENTINEL"))
  assert(LocalStore(directory: dir).data.results == store.data.results)
  print("Result workflow: 7 checks passed")
 }
}
