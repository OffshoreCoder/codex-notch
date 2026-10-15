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
            let spool = EventSpool(directory: EventSpool.defaultDirectory)
            try spool.append(event)
            if let attention = CompanionEvent.attentionFromHook(input, now: event.timestamp) { try spool.append(attention) }
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

if arguments.contains("--attention") {
    guard arguments.count == 6, Set(stride(from: 0, to: 6, by: 2).map { arguments[$0] }) == Set(["--attention", "--session", "--turn"]),
          let kind = option("--attention"), let session = option("--session"), let turn = option("--turn"),
          let event = CompanionEvent.explicitAttention(kind: kind, session: session, turn: turn) else {
        fputs("Нужны --attention question|review|clear --session UUID --turn TURN_ID\n", stderr); exit(2)
    }
    do { try EventSpool(directory: EventSpool.defaultDirectory).append(event) }
    catch { fputs("Не удалось отправить сигнал: \(error.localizedDescription)\n", stderr); exit(1) }
    print("Сигнал отправлен. Он применяется только к совпадающему известному ходу.")
    exit(0)
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

if arguments.contains("--health") {
    let report = IntegrationHealth.check(hooksURL: URL(fileURLWithPath: option("--hooks-file") ??
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json").path),
        executableURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
        spoolDirectory: EventSpool.defaultDirectory, runSelfTest: arguments.contains("--self-test"))
    print(report.summary)
    for check in report.checks { print("[\(check.status.rawValue)] \(check.title): \(check.detail)") }
    exit(report.hasFailures ? 1 : 0)
}

if arguments.contains("--help") {
    print("""
    CodexNotch — локальный персонаж у выреза Mac.
      --attention KIND --session UUID --turn ID  явный question/review/clear
      --preview-dashboard    вместе с --preview отрисовать демонстрацию пульта
      --health [--self-test] проверить настройки/путь и локальную запись без AppKit
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
    private var dashboardShortcut: GlobalShortcutController?
    private var health: HealthController!
    private var previewDirectory: URL?
    private var codexNames: [String: String] = [:]
    private let nameReader = ThreadNames()
    private var lastNameRead = Date.distantPast
    private var lastNameIDs: [String] = []
    private var nameReadInFlight = false
    private var nameReport: ThreadNames.Result?
    private var contexts: [String: ProjectContext] = [:]
    private var contextReadInFlight = false
    private var lastContextRead = Date.distantPast
    private var timer: Timer?
    private var demo = option("--demo").flatMap(CompanionState.init(rawValue:))
    private let spool = EventSpool(directory: EventSpool.defaultDirectory)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if option("--preview") == nil && !acquireInstanceLock() {
            fputs("CodexNotch уже запущен или папка событий недоступна.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        if option("--preview") != nil {
            previewDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexNotch-preview-" + UUID().uuidString)
        }
        library = LocalStore(directory: previewDirectory ?? spool.directory)
        controller = NotchController()
        dashboard = DashboardController(handler: { [weak self] action in self?.handle(action) })
        health = HealthController(reportProvider: { [weak self] selfTest in
            let baseReport = IntegrationHealth.check(hooksURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/hooks.json"),
                executableURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
                spoolDirectory: EventSpool.defaultDirectory, runSelfTest: selfTest)
            let last = self?.library.data.lastRealEvent
            let text = last.map { "Последнее реальное событие: " + Self.duration(Date().timeIntervalSince($0)) + " назад" }
                ?? "Реальных событий ещё не получено. Это не доказывает сбой подключения."
            let names = self?.nameReport
            let nameCheck = IntegrationHealth.Check(id: "thread-names", title: "Названия чатов",
                detail: names?.detail ?? "Проверка источника названий ещё выполняется.",
                status: names?.status == .available ? .ok : .warning)
            return (IntegrationHealth.Report(checks: baseReport.checks + [nameCheck]), text)
        })
        controller.healthHandler = { [weak self] in self?.health.show() }
        controller.dashboardHandler = { [weak self] in
            guard let self else { return }
            self.controller.dismissStateCard()
            if let location = self.controller.dashboardLocation() {
                self.dashboard.toggle(anchor: location.anchor, screen: location.screen)
            } else { self.dashboard.show() }
        }
        if option("--preview") == nil {
            dashboardShortcut = GlobalShortcutController { [weak self] in
                guard let self else { return }
                self.controller.dismissStateCard()
                let location = self.controller.dashboardLocation()
                self.dashboard.showForKeyboard(anchor: location?.anchor, screen: location?.screen)
            }
            updateShortcutStatus()
        }
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
                if arguments.contains("--preview-dashboard") {
                    self?.populatePreview()
                    if let self, let location = self.controller.dashboardLocation() {
                        self.dashboard.show(anchor: location.anchor, screen: location.screen)
                    } else { self?.dashboard.show() }
                    self?.dashboard.capturePreview(to: URL(fileURLWithPath: path))
                } else if arguments.contains("--compact-preview") {
                    self?.controller.captureCompactPreview(to: URL(fileURLWithPath: path))
                } else {
                    self?.controller.capturePreview(to: URL(fileURLWithPath: path))
                }
                if let reportPath = option("--layout-report"),
                   var report = self?.controller.layoutReport() {
                    report["dashboardFrame"] = self?.dashboard.layoutReport()
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                    }
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
    }

    private func refresh() {
        // Replay queued events before the single end-of-quiet summary, including after restart.
        controller.setQuiet(library.isQuiet() || library.quietExpired())
        if option("--preview") == nil {
            let events = spool.drain()
            for event in events {
                let previous = model.chatSummaries().first { $0.id == event.sessionID } ?? library.data.chats[event.sessionID]
                model.receive(event)
                let current = model.chatSummaries().first { $0.id == event.sessionID } ?? library.data.chats[event.sessionID]
                if library.receiveAttention(event, current: current, deferNotification: library.quietExpired()),
                   library.shouldNotify(event.sessionID, now: event.timestamp) {
                    controller.notify(title: event.event == "AttentionQuestion" ? "Нужен твой ответ" : "Посмотри результат",
                                      sessionID: event.sessionID)
                }
                let accepted = event.event == "SessionEnd"
                    ? (previous.map { event.timestamp >= $0.updatedAt } ?? true)
                    : (current?.updatedAt == event.timestamp)
                if accepted { library.rememberWorkingDirectory(event) }
                if accepted, ["Stop", "Interrupt"].contains(event.event) { library.remember(model.chatSummaries()) }
                library.clearAttentionForLifecycle(event, accepted: accepted)
                if event.event == "SessionEnd", accepted { library.endSession(event.sessionID, at: event.timestamp) }
                if let result = model.completion(for: event),
                   library.record(result, now: event.timestamp, deferNotification: library.quietExpired()) {
                    if library.shouldNotify(result.sessionID, now: event.timestamp), library.data.attention[result.id] == nil {
                        controller.notify(title: "Ход завершён", sessionID: result.sessionID)
                    }
                }
                if event.event == "Interrupt", library.shouldNotify(event.sessionID, now: event.timestamp),
                   model.chatSummaries().contains(where: {
                       $0.id == event.sessionID && $0.state == .interrupted && $0.updatedAt == event.timestamp
                   }) {
                    controller.notify(title: "Ход остановлен", sessionID: event.sessionID, duration: 4)
                }
            }
            if !events.isEmpty {
                library.remember(model.chatSummaries())
                if let last = events.filter({ CompanionEvent.hookEvents.contains($0.event) }).map(\.timestamp).max() { library.recordLastEvent(last) }
            }
        }
        for reminder in library.pollReminders(liveChats: model.chatSummaries()) {
            controller.notify(title: reminder.kind == .result ? "Пора посмотреть результат" : "Ход всё ещё выполняется",
                              sessionID: reminder.sessionID)
        }
        if library.quietExpired() { finishQuiet() }
        controller.setQuiet(library.isQuiet())
        let live = model.snapshot()
        let attention = library.data.attention.values.sorted { $0.requestedAt > $1.requestedAt }.first
        let attentionSnapshot = attention.map {
            CompanionSnapshot(state: $0.state, sessionID: $0.sessionID, activeCount: live.activeCount, updatedAt: $0.requestedAt)
        }
        let snapshot = demo.map {
            CompanionSnapshot(state: $0, sessionID: nil, activeCount: [.working, .coding, .checking].contains($0) ? 1 : 0, updatedAt: Date())
        } ?? attentionSnapshot ?? live
        controller.update(snapshot)
        controller.updateQueue(library.data.completions, error: library.error,
            pendingCount: Set(library.data.completions.map(\.id) + Array(library.data.attention.keys)).count,
            chatNames: library.data.labels.merging(codexNames) { manual, _ in manual })
        updateDashboard()
    }

    private func handle(_ action: DashboardAction) {
        switch action {
        case .openChat(let id):
            if controller.openChat(id) {
                library.acknowledgeChat(id)
                dashboard.hide()
            }
        case .acknowledgeChat(let id): library.acknowledgeChat(id)
        case .rename(let id, let name): library.rename(id, to: name == codexNames[id.lowercased()] ? "" : name)
        case .important(let id): library.selectImportant(id)
        case .quiet(let seconds): library.beginQuiet(seconds: seconds)
        case .endQuiet: finishQuiet()
        case .remindCompleted(let id, let seconds): library.remindResult(id, after: seconds)
        case .watchDuration(let id, let seconds):
            if let chat = model.chatSummaries().first(where: { $0.id == id }) { library.watchDuration(chat, threshold: seconds) }
        case .cancelReminders(let id): library.cancelReminders(id)
        case .configureShortcut(let value):
            if let dashboardShortcut {
                let changed = dashboardShortcut.configure(value)
                updateShortcutStatus()
                if !changed {
                    let alert = NSAlert()
                    alert.messageText = "Сочетание недоступно"
                    alert.informativeText = dashboardShortcut.error ?? "Выбери другое сочетание клавиш."
                    alert.addButton(withTitle: "Понятно")
                    alert.runModal()
                }
            }
        case .copyAttentionInstruction:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.attentionInstruction, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Инструкция скопирована"
            alert.informativeText = "Вставь её в нужный чат Codex. Сигналы появятся, когда агент выполнит точный маркер через shell. Проверки разрешений не используются."
            alert.addButton(withTitle: "Понятно")
            alert.runModal()
        }
        refresh()
    }

    private func updateShortcutStatus() {
        guard let dashboardShortcut else { return }
        dashboard.updateShortcut(dashboardShortcut.shortcut, enabled: dashboardShortcut.isEnabled,
                                 error: dashboardShortcut.error)
    }

    private func finishQuiet() {
        let count = library.endQuiet()
        controller.setQuiet(false)
        if count > 0 { controller.notify(title: "Пора вернуться: \(count)") }
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
        let ordered = all.values.sorted { left, right in
            let l = library.data.completions.contains { $0.sessionID == left.id }
            let r = library.data.completions.contains { $0.sessionID == right.id }
            return l != r ? l : left.updatedAt > right.updatedAt
        }
        refreshNames(sessionIDs: ordered.map(\.id))
        refreshContexts()
        let entries = ordered.map { saved -> DashboardEntry in
            let chat = live[saved.id] ?? saved
            let state = live[saved.id] == nil && [.working, .coding, .checking].contains(saved.state)
                ? CompanionState.unknown : chat.state
            let duration = chat.startedAt.map {
                (state == .finished || state == .interrupted ? chat.endedAt ?? chat.updatedAt : Date()).timeIntervalSince($0)
            }
            let elapsed = duration.map { "Ход: " + Self.duration($0) } ?? ""
            let request = library.data.attention.values.first { $0.sessionID == chat.id }
            let deferred = library.data.deferredReminders.filter { $0.sessionID == chat.id }
            var entry = DashboardEntry(id: chat.id, name: displayName(for: chat.id),
                stateText: request?.state.companionTitle ?? (state == .finished ? "Ход завершён" : state.companionTitle),
                elapsedText: state == .unknown ? "Последнее известное состояние" : elapsed,
                updatedText: "Последний сигнал: " + Self.duration(Date().timeIntervalSince(chat.updatedAt)) + " назад",
                unreadCount: library.data.completions.filter { $0.sessionID == chat.id }.count,
                isImportant: library.data.importantSessionID == chat.id,
                canRemindResult: library.data.completions.contains { $0.sessionID == chat.id },
                canWatchDuration: live[chat.id] != nil && [.working, .coding, .checking].contains(state) && chat.startedAt != nil,
                reminderText: library.data.reminders.filter { $0.sessionID == chat.id }.map {
                    ($0.kind == .result ? "Вернуться через " : "Проверить длительность через ") +
                        Self.duration($0.dueAt.timeIntervalSinceNow)
                }.joined(separator: " · ") + (deferred.isEmpty ? "" : " · Напоминание ожидает окончания тишины"),
                attentionText: request == nil ? "" : "Требует внимания")
            entry.contextText = contexts[chat.id]?.displayText ?? ""
            entry.contextPath = contexts[chat.id]?.workingDirectory ?? ""
            if request != nil { entry.status = .attention }
            else if [.working, .coding, .checking].contains(state) { entry.status = .running }
            else if state == .finished { entry.status = .completed }
            else if state == .interrupted { entry.status = .interrupted }
            else if state == .unknown { entry.status = .unknown }
            else { entry.status = .idle }
            return entry
        }
        dashboard.update(entries: entries)
    }

    private func displayName(for sessionID: String) -> String {
        library.data.labels[sessionID] ?? codexNames[sessionID.lowercased()] ?? "Чат без названия"
    }

    private func refreshContexts() {
        guard option("--preview") == nil, !contextReadInFlight, Date().timeIntervalSince(lastContextRead) >= 5 else { return }
        let directories = library.data.workingDirectories
        contextReadInFlight = true
        lastContextRead = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = ProjectContextReader()
            let result = directories.compactMapValues { reader.read(workingDirectory: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.contexts = result
                self.contextReadInFlight = false
                self.updateDashboard()
            }
        }
    }

    private func refreshNames(sessionIDs: [String]) {
        guard option("--preview") == nil, !nameReadInFlight else { return }
        let ids = Array(sessionIDs.prefix(512))
        let membership = ids.sorted()
        guard membership != lastNameIDs || Date().timeIntervalSince(lastNameRead) >= 5 else { return }
        lastNameIDs = membership
        lastNameRead = Date()
        nameReadInFlight = true
        let reader = nameReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = reader.read(sessionIDs: ids)
            DispatchQueue.main.async {
                guard let self else { return }
                if result.status == .available { self.codexNames = result.names }
                else { self.codexNames = self.codexNames.filter { ids.contains($0.key) } }
                self.nameReport = result
                self.nameReadInFlight = false
                self.updateDashboard()
            }
        }
    }

    private static let attentionInstruction = """
    Подключи в этом чате явные сигналы Codex Notch. Непосредственно перед настоящим вопросом ко мне выполни отдельной shell-командой точно:
    : codex-notch:question
    Перед просьбой посмотреть или проверить готовый результат:
    : codex-notch:review
    Если просьба больше не актуальна:
    : codex-notch:clear
    Это no-op маркеры для локального hook PostToolUse. Используй прямой shell tool, без обёртки JavaScript, echo, дополнительных команд и перенаправлений. Не отправляй question для проверки разрешения, обычной работы или простого завершения хода. Не отправляй marker заранее. Если shell недоступен, просто продолжай общение; не утверждай, что сигнал был отправлен.
    """

    private func populatePreview() {
        var entries = [
            DashboardEntry(id: "demo-a", name: "Review библиотеки", stateText: "Посмотри результат", elapsedText: "Ход: 7 мин", updatedText: "Последний сигнал: 12 с назад", unreadCount: 1, isImportant: true, canRemindResult: true, attentionText: "Требует внимания"),
            DashboardEntry(id: "demo-b", name: "Исправление сборки", stateText: "Пишет код", elapsedText: "Ход: 3 мин", updatedText: "Последний сигнал: 2 с назад", unreadCount: 0, canWatchDuration: true, reminderText: "Проверить длительность через 7 мин"),
            DashboardEntry(id: "demo-c", name: "Проверка тестов", stateText: "Ход завершён", elapsedText: "Ход: 42 с", updatedText: "Последний сигнал: 2 мин назад", unreadCount: 2, canRemindResult: true)
        ]
        entries[0].status = .attention
        entries[1].status = .running
        entries[2].status = .completed
        dashboard.update(entries: entries)
        dashboard.updateQuiet(status: "Тишина ещё 18 мин", active: true)
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
