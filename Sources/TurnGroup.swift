import Foundation

enum GroupTurnStatus: String, Codable { case running, finished, interrupted, closed, replaced }
struct GroupTurn: Codable, Equatable, Identifiable {
    let sessionID: String
    let turnID: String
    var status: GroupTurnStatus = .running
    var id: String { sessionID + "|" + turnID }
}
struct TurnGroup: Codable, Equatable {
    var turns: [GroupTurn]
    var notified = false
    var settled: Int { turns.filter { $0.status != .running }.count }
    var isComplete: Bool { !turns.isEmpty && settled == turns.count }
    var interrupted: Int { turns.filter { $0.status == .interrupted }.count }
    var text: String {
        let stopped = interrupted > 0 ? " · остановлено: \(interrupted)" : ""
        let other = turns.filter { [.closed, .replaced].contains($0.status) }.count
        return "Завершены \(settled) из \(turns.count)" + stopped + (other > 0 ? " · закрыты/сменились: \(other)" : "")
    }
    mutating func receive(_ event: CompanionEvent, accepted: Bool) {
        guard accepted else { return }
        for index in turns.indices where turns[index].sessionID == event.sessionID && turns[index].status == .running {
            let same = event.turnID == turns[index].turnID
            switch event.event {
            case "Stop" where same: turns[index].status = .finished
            case "Interrupt" where same: turns[index].status = .interrupted
            case "SessionEnd" where same || event.turnID == nil: turns[index].status = .closed
            case "UserPromptSubmit" where !same: turns[index].status = .replaced
            default: break
            }
        }
    }
}
