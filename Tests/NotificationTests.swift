import Foundation
@main struct NotificationTests {
    static func main() {
        let now = Date()
        let short = CompletedTurn(sessionID: "s", turnID: "short", startedAt: now.addingTimeInterval(-10), finishedAt: now)
        let long = CompletedTurn(sessionID: "s", turnID: "long", startedAt: now.addingTimeInterval(-600), finishedAt: now)
        let noStart = CompletedTurn(sessionID: "s", turnID: "unknown", startedAt: nil, finishedAt: now)
        let question = LocalNotice(title: "Нужен твой ответ", sessionID: "s", key: long.id)
        func notices(_ turns: [CompletedTurn], _ explicit: [LocalNotice] = [], foreground: Bool = false, catchup: Bool = false) -> [LocalNotice] {
            NotificationPolicy.notices(completions: turns, explicit: explicit, interruptions: [], codexForeground: foreground, catchingUp: catchup, now: now)
        }
        assert(notices([short, noStart]).isEmpty)
        assert(notices([long]).count == 1)
        assert(notices([long], foreground: true).isEmpty)
        assert(notices([long], [question], foreground: true) == [question])
        assert(notices([short, long], [question], catchup: true).count == 1)
        assert(notices([], catchup: true).isEmpty)
        assert(notices([short, long], [question], catchup: true).first?.title.contains("1 событий") == true)
        assert(notices([short], foreground: true, catchup: true).isEmpty)
        assert(notices([long], foreground: true, catchup: true).isEmpty)
        print("Notification policy: 9 checks passed")
    }
}
