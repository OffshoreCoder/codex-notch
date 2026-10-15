import Foundation

struct LocalNotice: Equatable {
    let title: String
    var sessionID: String? = nil
    var key: String = ""
}

enum NotificationPolicy {
    static let longTurn: TimeInterval = 60
    static func pendingExplicit(_ notices: [LocalNotice], requests: [String: AttentionRequest]) -> [LocalNotice] {
        var seen = Set<String>()
        return notices.filter { notice in
            guard let request = requests[notice.key],
                  notice.title == (request.kind == .question ? "Нужен твой ответ" : "Посмотри результат") else { return false }
            return seen.insert(notice.key).inserted
        }
    }
    /// Quiet mode / selected-chat filtering happens before this pure policy.
    static func notices(completions: [CompletedTurn], explicit: [LocalNotice], interruptions: [LocalNotice],
                        codexForeground: Bool, catchingUp: Bool, now: Date = Date()) -> [LocalNotice] {
        let explicitKeys = Set(explicit.map(\.key))
        let normal = codexForeground ? [] : completions.filter {
            !explicitKeys.contains($0.id) && $0.startedAt.map { $0 <= now } == true &&
                $0.finishedAt.timeIntervalSince($0.startedAt!) >= longTurn
        }.map { LocalNotice(title: "Ход завершён", sessionID: $0.sessionID, key: $0.id) }
        if catchingUp {
            let keys = Set(normal.map(\.key) + explicit.map(\.key) + interruptions.map(\.key))
            return keys.isEmpty ? [] : [LocalNotice(title: "Пока тебя не было: \(keys.count) событий")]
        }
        // One card per poll avoids hiding an important question behind a normal completion.
        if let question = explicit.first(where: { $0.title == "Нужен твой ответ" }) { return [question] }
        let all = explicit + interruptions + normal
        if all.count > 1 { return [LocalNotice(title: "Новых событий: \(Set(all.map(\.key)).count)")] }
        return all
    }
}
