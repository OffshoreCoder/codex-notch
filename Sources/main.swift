import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

// Hook path deliberately runs before AppKit setup. It never opens windows or decides approvals.
if arguments.contains("--hook") {
    do {
        var input = Data()
        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            input.append(chunk)
            if input.count > 16 * 1024 * 1024 { break }
        }
        if input.count <= 16 * 1024 * 1024, let event = CompanionEvent.fromHook(input) {
            try EventSpool(directory: EventSpool.defaultDirectory).append(event)
        }
    } catch {
        // An absent/unwritable companion must never block the user's agent.
    }
    print("{}")
    exit(0)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--connect-hooks") || arguments.contains("--disconnect-hooks") || arguments.contains("--print-hooks") {
    let hooksURL = URL(fileURLWithPath: option("--hooks-file") ??
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json").path)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    do {
        if arguments.contains("--print-hooks") {
            let result = try HookConfiguration.preview(at: hooksURL, executableURL: executable)
            FileHandle.standardOutput.write(result)
            print("")
        } else if arguments.contains("--disconnect-hooks") {
            print(try HookConfiguration.disconnect(at: hooksURL))
        } else {
            print(try HookConfiguration.connect(at: hooksURL, executableURL: executable))
            print("В терминале запустите codex и откройте /hooks: проверьте и доверьте новые обработчики. Затем откройте новый чат.")
        }
    } catch {
        fputs("CodexNotch: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    exit(0)
}

if arguments.contains("--help") {
    print("""
    CodexNotch — локальный персонаж у выреза Mac.
      --demo STATE           idle/working/coding/checking/finished/interrupted/unknown
      --preview PATH         сохранить изображение собственного окна и завершить
      --compact-preview      вместе с --preview сохранить крошечного персонажа
      --layout-report PATH   вместе с --preview сохранить геометрию собственного окна
      --print-hooks          показать результат слияния hooks.json без записи
      --connect-hooks        добавить только свои hooks с резервной копией
      --disconnect-hooks     удалить только свои hooks с резервной копией
      --hooks-file PATH      другой файл hooks.json для проверки настройки
      --hook --codex-notch   внутренний обработчик JSON на stdin
    CODEX_NOTCH_DATA_DIR      другая локальная папка событий (для тестов)
    """)
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController!
    private var model = CompanionModel()
    private var library: LocalStore!
    private var dashboard: DashboardController!
    private var timer: Timer?
    private var demo = option("--demo").flatMap(CompanionState.init(rawValue:))
    private let spool = EventSpool(directory: EventSpool.defaultDirectory)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if option("--preview") == nil && !acquireInstanceLock() {
            fputs("CodexNotch уже запущен или папка событий недоступна.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        library = LocalStore(directory: option("--preview") == nil ? spool.directory :
            FileManager.default.temporaryDirectory.appendingPathComponent("CodexNotch-preview-" + UUID().uuidString))
        controller = NotchController()
        dashboard = DashboardController(handler: { [weak self] action in self?.handle(action) })
        controller.dashboardHandler = { [weak self] in self?.dashboard.show() }
        controller.acknowledgeHandler = { [weak self] id in
            guard let self else { return }
            if let id { self.library.acknowledge(id) } else { self.library.acknowledgeAll() }
            self.refresh()
        }
        controller.demoHandler = { [weak self] state in self?.demo = state; self?.refresh() }
        controller.liveHandler = { [weak self] in self?.demo = nil; self?.refresh() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if let path = option("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if arguments.contains("--compact-preview") {
                    self?.controller.captureCompactPreview(to: URL(fileURLWithPath: path))
                } else {
                    self?.controller.capturePreview(to: URL(fileURLWithPath: path))
                }
                if let reportPath = option("--layout-report"),
                   let report = self?.controller.layoutReport(),
                   let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func refresh() {
        if library.quietExpired() { finishQuiet() }
        controller.setQuiet(library.isQuiet())
        if option("--preview") == nil {
            let events = spool.drain()
            for event in events {
                model.receive(event)
                if let result = model.completion(for: event), library.record(result) {
                    if library.shouldNotify(result.sessionID) {
                        controller.notify(title: "Ход завершён", sessionID: result.sessionID)
                    }
                }
                if event.event == "Interrupt", library.shouldNotify(event.sessionID),
                   model.chatSummaries().contains(where: {
                       $0.id == event.sessionID && $0.state == .interrupted && $0.updatedAt == event.timestamp
                   }) {
                    controller.notify(title: "Ход остановлен", sessionID: event.sessionID, duration: 4)
                }
            }
            if !events.isEmpty { library.remember(model.chatSummaries()) }
        }
        let live = model.snapshot()
        let snapshot = demo.map {
            CompanionSnapshot(state: $0, sessionID: nil, activeCount: [.working, .coding, .checking].contains($0) ? 1 : 0, updatedAt: Date())
        } ?? live
        controller.update(snapshot)
        controller.updateQueue(library.data.completions, error: library.error)
        updateDashboard()
    }

    private func handle(_ action: DashboardAction) {
        switch action {
        case .openChat(let id):
            if controller.openChat(id) { library.acknowledgeChat(id) }
        case .acknowledgeChat(let id): library.acknowledgeChat(id)
        case .rename(let id, let name): library.rename(id, to: name)
        case .important(let id): library.selectImportant(id)
        case .quiet(let seconds): library.beginQuiet(seconds: seconds)
        case .endQuiet: finishQuiet()
        }
        refresh()
    }

    private func finishQuiet() {
        let count = library.endQuiet()
        controller.setQuiet(false)
        if count > 0 { controller.notify(title: "Ждут просмотра: \(count)") }
    }

    private func updateDashboard() {
        let quietText = library.data.quietIndefinitely ? "Тишина до выключения" : library.data.quietUntil.map {
            "Тишина ещё " + Self.duration($0.timeIntervalSinceNow)
        } ?? "Уведомления включены"
        dashboard.updateQuiet(status: quietText, active: library.isQuiet())
        let live = Dictionary(uniqueKeysWithValues: model.chatSummaries().map { ($0.id, $0) })
        var all = library.data.chats
        for result in library.data.completions where all[result.sessionID] == nil {
            all[result.sessionID] = ChatSummary(id: result.sessionID, turnID: result.turnID,
                state: .finished, startedAt: result.startedAt, updatedAt: result.finishedAt)
        }
        let entries = all.values.sorted { left, right in
            let l = library.data.completions.contains { $0.sessionID == left.id }
            let r = library.data.completions.contains { $0.sessionID == right.id }
            return l != r ? l : left.updatedAt > right.updatedAt
        }.map { saved -> DashboardEntry in
            let chat = live[saved.id] ?? saved
            let state = live[saved.id] == nil && [.working, .coding, .checking].contains(saved.state)
                ? CompanionState.unknown : chat.state
            let duration = chat.startedAt.map {
                (state == .finished || state == .interrupted ? chat.updatedAt : Date()).timeIntervalSince($0)
            }
            let elapsed = duration.map { "Ход: " + Self.duration($0) } ?? ""
            return DashboardEntry(id: chat.id, name: library.name(for: chat.id),
                stateText: state == .finished ? "Ход завершён" : state.companionTitle,
                elapsedText: state == .unknown ? "Последнее известное состояние" : elapsed,
                updatedText: "Последний сигнал: " + Self.duration(Date().timeIntervalSince(chat.updatedAt)) + " назад",
                unreadCount: library.data.completions.filter { $0.sessionID == chat.id }.count,
                isImportant: library.data.importantSessionID == chat.id)
        }
        dashboard.update(entries: entries)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? "\(total) с" : total < 3600 ? "\(total / 60) мин" : "\(total / 3600) ч \(total % 3600 / 60) мин"
    }

    private var lockDescriptor: Int32 = -1
    private func acquireInstanceLock() -> Bool {
        do { try spool.prepare() } catch { return false }
        let path = spool.directory.appendingPathComponent("app.lock").path
        lockDescriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockDescriptor >= 0 else { return false }
        return flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
