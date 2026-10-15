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
            if let result = CompanionEvent.resultFromHook(input, now: event.timestamp) { try spool.append(result) }
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
      --preview-scene NAME   panel/result/sharing/group/awake/statistics/settings, выдуманные данные
      --preview-scale N      масштаб compact-preview, от 1 до 16
      --health [--self-test] проверить настройки/путь и локальную запись без AppKit
      --demo STATE           idle/working/coding/checking/finished/interrupted/unknown
      --preview PATH         сохранить изображение собственного окна и завершить
      --compact-preview      вместе с --preview сохранить крошечного персонажа
      --skin NAME            robot/cat/ghost/astronaut для preview без изменения выбора
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
    private let keepAwake = KeepAwakeController()
    private var keepAwakeQuestions = KeepAwakeQuestions()
    private var powerEventsAfter = Date.distantPast
    private var library: LocalStore!
    private var dashboard: DashboardController!
    private var settings: SettingsController?
    private var statistics: TaskStatistics!
    private var statisticsWindow: StatisticsController?
    private var tokenReport = TaskTokenReader.Result.unavailable
    private var tokenReadInFlight = false
    private var lastTokenRead = Date.distantPast
    private var lastStatisticsRender = Date.distantPast
    private var dashboardShortcut: GlobalShortcutController?
    private var health: HealthController!
    private var previewDirectory: URL?
    private let sharedInstance = InstanceLock()
    private var instanceObserver: NSObjectProtocol?
    private let showDashboardNotification = Notification.Name("local.codex.notch.show-dashboard")
    private var privacy = PrivacyPresentation()
    private var codexNames: [String: String] = [:]
    private let nameReader = ThreadNames()
    private var lastNameRead = Date.distantPast
    private var lastNameIDs: [String] = []
    private var nameReadInFlight = false
    private var nameReport: ThreadNames.Result?
    private var contexts: [String: ProjectContext] = [:]
    private var contextReadInFlight = false
    private var lastContextRead = Date.distantPast
    private var groupSelection = Set<String>()
    private var lastPoll = Date.distantPast
    private var resumed = false
    private var sessionActive = true
    private var absenceCompletions: [CompletedTurn] = []
    private var absenceExplicit: [LocalNotice] = []
    private var absenceInterruptions: [LocalNotice] = []
    private var wakeObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var heartbeatInterval: TimeInterval = 0
    private var spoolWatcher: EventWake?
    private var displaySleeping = false
    private var demo = option("--demo").flatMap(CompanionState.init(rawValue:))
    private let spool = EventSpool(directory: EventSpool.defaultDirectory)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if option("--preview") == nil && !acquireInstanceLock() {
            fputs("CodexNotch уже запущен или папка событий недоступна.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        if option("--preview") == nil, ProcessInfo.processInfo.environment["CODEX_NOTCH_DATA_DIR"] == nil {
            EventSpool.rememberSharedDirectory(spool.directory)
        }
        if option("--preview") != nil {
            previewDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexNotch-preview-" + UUID().uuidString)
        }
        library = LocalStore(directory: previewDirectory ?? spool.directory)
        statistics = TaskStatistics(directory: previewDirectory ?? spool.directory,
            now: option("--preview") == nil ? Date() : Date().addingTimeInterval(-86400))
        statistics.setEnabled(library.data.statisticsEnabled)
        controller = NotchController()
        dashboard = DashboardController(handler: { [weak self] action in self?.handle(action) })
        if option("--preview") == nil, ProcessInfo.processInfo.environment["CODEX_NOTCH_DATA_DIR"] == nil {
            instanceObserver = DistributedNotificationCenter.default().addObserver(forName: showDashboardNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.revealDashboard() }
                }
        }
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
            let power = self?.keepAwake
            let powerCheck = IntegrationHealth.Check(id: "keep-awake", title: "Режим сна",
                detail: (power?.statusText ?? "Обычный режим сна") + (power?.lastError.map { " · " + $0 } ?? ""),
                status: power?.status == .failed || power?.lastError != nil ? .warning : .ok)
            return (IntegrationHealth.Report(checks: baseReport.checks + [nameCheck, powerCheck]), text)
        })
        controller.healthHandler = { [weak self] in self?.showHealth() }
        controller.settingsHandler = { [weak self] in self?.handle(.openSettings) }
        controller.statisticsHandler = { [weak self] in self?.handle(.openStatistics) }
        controller.keepAwakeHandler = { [weak self] in self?.handle(.toggleKeepAwake) }
        controller.skinHandler = { [weak self] skin in self?.handle(.selectSkin(skin)) }
        controller.screenSharingHandler = { [weak self] in self?.handle(.toggleSharing) }
        controller.dashboardHandler = { [weak self] in
            guard let self else { return }
            self.settings?.hide()
            self.controller.dismissStateCard()
            if let location = self.controller.dashboardLocation() {
                self.dashboard.toggle(anchor: location.anchor, screen: location.screen)
            } else { self.dashboard.show() }
            self.refresh()
        }
        if option("--preview") == nil {
            dashboardShortcut = GlobalShortcutController { [weak self] in
                guard let self else { return }
                self.settings?.hide()
                self.controller.dismissStateCard()
                let location = self.controller.dashboardLocation()
                self.dashboard.showForKeyboard(anchor: location?.anchor, screen: location?.screen)
                self.refresh()
            }
            updateShortcutStatus()
        }
        controller.acknowledgeHandler = { [weak self] id in
            guard let self else { return }
            if let id { self.library.markOpened(id) } else { self.library.acknowledgeAll() }
            self.refresh()
        }
        controller.demoHandler = { [weak self] state in self?.demo = state; self?.refresh() }
        controller.liveHandler = { [weak self] in self?.demo = nil; self?.refresh() }
        if option("--preview") == nil {
            spoolWatcher = EventWake(directory: spool.directory) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            spoolWatcher?.start()
            for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
                wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.displaySleeping = name == NSWorkspace.screensDidSleepNotification
                        self?.refresh()
                    }
                })
            }
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.powerEventsAfter = Date()
                    self?.keepAwake.stop()
                    self?.statistics.suspend()
                }
            })
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionActive = false }
            })
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.resumed = true
                        if name == NSWorkspace.sessionDidBecomeActiveNotification { self?.sessionActive = true }
                        if name == NSWorkspace.didWakeNotification {
                            self?.powerEventsAfter = Date()
                            self?.keepAwake.stop()
                        }
                        self?.refresh()
                    }
                })
            }
        }
        refresh()
        if let path = option("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if option("--preview-scene") == "settings", let self {
                    _ = self.makeSettings()
                    self.updateSettings()
                    if let location = self.controller.dashboardLocation() {
                        self.makeSettings().show(anchor: location.anchor, screen: location.screen)
                    } else { self.makeSettings().show() }
                    self.makeSettings().capturePreview(to: URL(fileURLWithPath: path))
                } else if option("--preview-scene") == "statistics", let self {
                    self.populateStatisticsPreview()
                    self.makeStatisticsWindow().show()
                    self.makeStatisticsWindow().capturePreview(to: URL(fileURLWithPath: path))
                } else if arguments.contains("--preview-dashboard") {
                    self?.populatePreview()
                    if let self, let location = self.controller.dashboardLocation() {
                        self.dashboard.show(anchor: location.anchor, screen: location.screen)
                    } else { self?.dashboard.show() }
                    self?.dashboard.capturePreview(to: URL(fileURLWithPath: path))
                } else if arguments.contains("--compact-preview") {
                    self?.controller.captureCompactPreview(to: URL(fileURLWithPath: path), scale: min(16, max(1, CGFloat(Double(option("--preview-scale") ?? "2") ?? 2))))
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
        keepAwake.stop()
        statistics?.suspend()
        spoolWatcher?.stop()
        timer?.invalidate()
        if let instanceObserver { DistributedNotificationCenter.default().removeObserver(instanceObserver) }
        sharedInstance.release()
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
    }

    private func refresh() {
        var completionNotices: [CompletedTurn] = []
        var explicitNotices: [LocalNotice] = []
        var interruptionNotices: [LocalNotice] = []
        var catchingUp = resumed || Date().timeIntervalSince(lastPoll) > 30
        resumed = false
        lastPoll = Date()
        // Replay queued events before the single end-of-quiet summary, including after restart.
        controller.setQuiet(library.isQuiet() || library.quietExpired())
        if option("--preview") == nil {
            let events = spool.drain()
            catchingUp = catchingUp || events.contains { Date().timeIntervalSince($0.timestamp) > 15 }
            for event in events {
                let previous = model.chatSummaries().first { $0.id == event.sessionID } ?? library.data.chats[event.sessionID]
                model.receive(event)
                let current = model.chatSummaries().first { $0.id == event.sessionID } ?? library.data.chats[event.sessionID]
                library.receiveResult(event, current: current)
                let attentionAccepted = library.receiveAttention(event, current: current, deferNotification: library.quietExpired())
                if attentionAccepted,
                   library.shouldNotify(event.sessionID, now: event.timestamp) {
                    explicitNotices.append(LocalNotice(title: event.event == "AttentionQuestion" ? "Нужен твой ответ" : "Посмотри результат",
                        sessionID: event.sessionID, key: event.sessionID + "|" + (event.turnID ?? "")))
                }
                let accepted = event.event == "SessionEnd"
                    ? (previous.map { event.timestamp >= $0.updatedAt } ?? true)
                    : (current?.updatedAt == event.timestamp)
                statistics.observe(event: event, accepted: accepted || attentionAccepted, current: current)
                keepAwakeQuestions.receive(event, current: current, attentionAccepted: attentionAccepted, lifecycleAccepted: accepted)
                library.restoreForEvent(event, accepted: accepted)
                library.receiveGroup(event, accepted: accepted, current: current)
                if accepted { library.rememberWorkingDirectory(event) }
                if accepted, ["Stop", "Interrupt"].contains(event.event) { library.remember(model.chatSummaries()) }
                library.clearAttentionForLifecycle(event, accepted: accepted)
                if event.event == "SessionEnd", accepted { library.endSession(event.sessionID, at: event.timestamp) }
                if let result = model.completion(for: event),
                   library.record(result, now: event.timestamp, deferNotification: library.quietExpired()) {
                    if library.shouldNotify(result.sessionID, now: event.timestamp), library.data.attention[result.id] == nil, !library.isGrouped(result.id) {
                        completionNotices.append(result)
                    }
                }
                if event.event == "Interrupt", library.shouldNotify(event.sessionID, now: event.timestamp),
                   !library.isGrouped(event.sessionID + "|" + (current?.turnID ?? event.turnID ?? "")),
                   model.chatSummaries().contains(where: {
                       $0.id == event.sessionID && $0.state == .interrupted && $0.updatedAt == event.timestamp
                   }) {
                    interruptionNotices.append(LocalNotice(title: "Ход остановлен", sessionID: event.sessionID, key: event.sessionID + "|" + (event.turnID ?? "")))
                }
            }
            if !events.isEmpty {
                library.remember(model.chatSummaries())
                if let last = events.filter({ CompanionEvent.hookEvents.contains($0.event) }).map(\.timestamp).max() { library.recordLastEvent(last) }
            }
        }
        if !sessionActive {
            absenceCompletions = Array((absenceCompletions + completionNotices).suffix(512))
            absenceExplicit = Array((absenceExplicit + explicitNotices).suffix(512))
            absenceInterruptions = Array((absenceInterruptions + interruptionNotices).suffix(512))
            completionNotices.removeAll(); explicitNotices.removeAll(); interruptionNotices.removeAll()
        } else {
            catchingUp = catchingUp || !absenceCompletions.isEmpty || !absenceExplicit.isEmpty || !absenceInterruptions.isEmpty
            completionNotices += absenceCompletions
            explicitNotices += absenceExplicit
            interruptionNotices += absenceInterruptions
            absenceCompletions.removeAll(); absenceExplicit.removeAll(); absenceInterruptions.removeAll()
            // A later clear/new turn in the same batch must revoke an obsolete popup.
            explicitNotices = NotificationPolicy.pendingExplicit(explicitNotices, requests: library.data.attention)
            if !library.data.attention.values.contains(where: { $0.kind == .question }) {
            for reminder in library.pollReminders(liveChats: model.chatSummaries()) {
                explicitNotices.append(LocalNotice(title: reminder.kind == .result ? "Пора посмотреть результат" : "Ход всё ещё выполняется",
                    sessionID: reminder.sessionID, key: reminder.targetKey))
            }
            if let text = library.pollGroupNotice() { explicitNotices.append(LocalNotice(title: text, key: "group")) }
            }
            let notices = NotificationPolicy.notices(completions: completionNotices, explicit: explicitNotices,
                interruptions: interruptionNotices, codexForeground: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.openai.codex",
                catchingUp: catchingUp)
            for notice in notices { controller.notify(title: notice.title, sessionID: notice.sessionID) }
        }
        if sessionActive, library.quietExpired() { finishQuiet() }
        controller.setQuiet(library.isQuiet())
        let liveChats = model.chatSummaries().filter { $0.updatedAt >= powerEventsAfter }
        let blocked = keepAwakeQuestions.blockedSessionIDs.union(library.data.attention.values.filter { $0.kind == .question }.map(\.sessionID))
        keepAwake.update(enabled: library.data.keepAwakeEnabled, isPreview: option("--preview") != nil || demo != nil,
            liveChats: liveChats, blockedSessionIDs: blocked)
        let awakeText = keepAwake.status == .waiting && !blocked.isEmpty ? "Ожидается твой ответ · сон разрешён" : keepAwake.statusText
        controller.setKeepAwake(enabled: library.data.keepAwakeEnabled, status: awakeText)
        let live = model.snapshot()
        let attention = library.data.attention.values.sorted { $0.requestedAt > $1.requestedAt }.first
        let attentionSnapshot = attention.map {
            CompanionSnapshot(state: $0.state, sessionID: $0.sessionID, activeCount: live.activeCount, updatedAt: $0.requestedAt)
        }
        let snapshot = demo.map {
            CompanionSnapshot(state: $0, sessionID: nil, activeCount: [.working, .coding, .checking].contains($0) ? 1 : 0, updatedAt: Date())
        } ?? attentionSnapshot ?? live
        privacy.observe(sessionIDs: library.data.chats.keys.sorted())
        controller.setScreenSharing(library.data.screenSharing, presentation: privacy)
        let skin = CharacterSkin(savedValue: option("--skin") ?? library.data.characterSkin)
        controller.setSkin(skin)
        updateSettings()
        controller.update(snapshot)
        controller.updateQueue(library.data.completions, error: library.error,
            pendingCount: Set(library.data.completions.map(\.id) + Array(library.data.attention.keys) + library.data.reviewingIDs).count,
            chatNames: Dictionary(uniqueKeysWithValues: library.data.chats.keys.map { ($0, displayName(for: $0)) }))
        updateDashboard()
        refreshStatistics()
        configureHeartbeat()
    }

    private func configureHeartbeat() {
        // Events wake us immediately. Timers only age state, service reminders and
        // renew the bounded idle-sleep lease; sleeping displays need no UI ticks.
        let interval: TimeInterval = !displaySleeping && (dashboard.isVisible || settings?.isVisible == true || statisticsWindow?.isVisible == true) ? 1
            : (!displaySleeping && model.snapshot().activeCount > 0 ? 5 : 30)
        if option("--preview") == nil { spoolWatcher?.start() }
        guard heartbeatInterval != interval else { return }
        heartbeatInterval = interval
        timer?.invalidate()
        let next = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        next.tolerance = min(2, interval * 0.2)
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    private func handle(_ action: DashboardAction) {
        switch action {
        case .openSettings: showSettings()
        case .openStatistics: showStatistics()
        case .openChat(let id):
            if controller.openChat(id) {
                library.openChat(id)
                dashboard.hide()
            }
        case .toggleKeepAwake: library.update { $0.keepAwakeEnabled.toggle() }
        case .selectSkin(let skin): library.update { $0.characterSkin = skin.rawValue }
        case .toggleSharing:
            library.update { $0.screenSharing.toggle() }
            health.hide()
            dashboard.setScreenSharing(library.data.screenSharing)
            statisticsWindow?.refresh()
        case .archive(let id): library.archive(id, liveChat: model.chatSummaries().first { $0.id == id })
        case .restoreArchive(let id): library.restoreArchive(id)
        case .toggleGroupSelection(let id):
            if groupSelection.contains(id) { groupSelection.remove(id) } else { groupSelection.insert(id) }
        case .startGroup:
            library.startGroup(model.chatSummaries().filter { groupSelection.contains($0.id) })
            groupSelection.removeAll()
        case .cancelGroup: library.cancelGroup()
        case .openAttachment(let key):
            if let result = library.data.results[key], let path = result.path, let valid = ResultSignal.safePath(path) {
                if NSWorkspace.shared.open(URL(fileURLWithPath: valid)) { library.markOpened(key); dashboard.hide() }
            } else {
                dashboard.showFeedback("Файл недоступен · открой чат, чтобы уточнить результат")
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
                    settings?.showFeedback(dashboardShortcut.error ?? "Сочетание занято · выбери другое")
                }
            }
        case .copyAttentionInstruction:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.attentionInstruction, forType: .string)
            dashboard.showFeedback("Скопировано: вставь в чат")
        }
        refresh()
    }

    private func updateShortcutStatus() {
        updateSettings()
    }

    private func makeSettings() -> SettingsController {
        if let settings { return settings }
        let value = SettingsController(handler: { [weak self] action in self?.handleSettings(action) })
        settings = value
        return value
    }

    private func makeStatisticsWindow() -> StatisticsController {
        if let statisticsWindow { return statisticsWindow }
        let value = StatisticsController(provider: { [unowned self] period in self.statisticsSnapshot(period) },
            action: { [weak self] action in
                guard let self else { return }
                switch action {
                case .openChat(let id): self.handle(.openChat(id)); self.statisticsWindow?.hide()
                case .assignTicket(let id, let ticket): _ = self.statistics.assign(ticket: ticket, to: id)
                case .reset: self.statistics.reset()
                }
            })
        statisticsWindow = value
        return value
    }

    private func showSettings() {
        let settings = makeSettings()
        dashboard.hide()
        controller.dismissStateCard()
        updateSettings()
        if let location = controller.dashboardLocation() {
            settings.show(anchor: location.anchor, screen: location.screen)
        } else { settings.show() }
    }

    private func revealDashboard() {
        settings?.hide()
        controller.dismissStateCard()
        if let location = controller.dashboardLocation() {
            dashboard.showForKeyboard(anchor: location.anchor, screen: location.screen)
        } else { dashboard.showForKeyboard(anchor: nil, screen: nil) }
        refresh()
    }

    private func showHealth() {
        if library.data.screenSharing {
            if settings?.isVisible == true { settings?.showFeedback("Для диагностики выключи скрытие названий") }
            else { dashboard.showFeedback("Для диагностики выключи режим демонстрации") }
        } else { settings?.hide(); dashboard.hide(); health.show() }
    }

    private func handleSettings(_ action: SettingsAction) {
        switch action {
        case .selectSkin(let skin): handle(.selectSkin(skin))
        case .toggleSharing: handle(.toggleSharing)
        case .toggleKeepAwake: handle(.toggleKeepAwake)
        case .configureShortcut(let shortcut): handle(.configureShortcut(shortcut))
        case .toggleStatistics:
            library.update { $0.statisticsEnabled.toggle() }
            statistics.setEnabled(library.data.statisticsEnabled)
            if !library.data.statisticsEnabled { tokenReport = .unavailable }
            lastTokenRead = .distantPast
            statisticsWindow?.refresh()
        case .openStatistics: showStatistics()
        case .openHealth: showHealth()
        case .quit: NSApplication.shared.terminate(nil); return
        }
        refresh()
    }

    private func updateSettings() {
        guard let settings else { return }
        let blocked = !keepAwakeQuestions.blockedSessionIDs.isEmpty || library.data.attention.values.contains { $0.kind == .question }
        let powerText = keepAwake.status == .waiting && blocked ? "Ожидается твой ответ · сон разрешён" : keepAwake.statusText
        settings.update(SettingsPreferences(skin: CharacterSkin(savedValue: option("--skin") ?? library.data.characterSkin),
            screenSharing: library.data.screenSharing, keepAwakeEnabled: library.data.keepAwakeEnabled,
            statisticsEnabled: library.data.statisticsEnabled,
            shortcut: dashboardShortcut?.shortcut ?? .standard, shortcutEnabled: dashboardShortcut?.isEnabled ?? true,
            shortcutError: dashboardShortcut?.error, energyStatus: "Адаптивная анимация · локальные события",
            powerStatus: powerText, powerActive: keepAwake.status == .active,
            powerFailed: keepAwake.status == .failed || keepAwake.lastError != nil, powerDetail: keepAwake.lastError,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.1"))
    }

    private func finishQuiet() {
        let count = library.endQuiet()
        controller.setQuiet(false)
        if count > 0 { controller.notify(title: "Пора вернуться: \(count)") }
    }

    private func updateDashboard() {
        guard !displaySleeping else { return }
        let quietText = library.data.quietIndefinitely ? "Тишина до выключения" : library.data.quietUntil.map {
            "Тишина ещё " + Self.duration($0.timeIntervalSinceNow)
        } ?? "Уведомления включены"
        dashboard.updateQuiet(status: quietText, active: library.isQuiet())
        let selectable = Set(model.chatSummaries().filter { [.working, .coding, .checking].contains($0.state) }.map(\.id))
        groupSelection.formIntersection(selectable)
        dashboard.updateGroup(text: library.data.turnGroup?.text, selectedCount: groupSelection.count, hasGroup: library.data.turnGroup != nil)
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
            let reviewing = library.data.reviewingIDs.contains { $0.hasPrefix(chat.id + "|") }
            let deferred = library.data.deferredReminders.filter { $0.sessionID == chat.id }
            var entry = DashboardEntry(id: chat.id, name: displayName(for: chat.id),
                stateText: reviewing ? "На проверке" : (request?.state.companionTitle ?? (state == .finished ? "Ход завершён" : state.companionTitle)),
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
            let currentKey = chat.turnID.map { chat.id + "|" + $0 }
            let result = currentKey.flatMap { library.data.results[$0] } ?? library.data.completions.reversed()
                .filter { $0.sessionID == chat.id }.compactMap { library.data.results[$0.id] }.first
            if let result {
                entry.resultID = result.id
                entry.canOpenResult = result.path != nil
                entry.resultText = (result.id == currentKey ? "" : "Предыдущий ход · ") + result.checkText
            }
            entry.isArchived = library.data.archivedChats[chat.id] != nil
            entry.canArchive = library.canArchive(chat.id, liveChat: live[chat.id])
            entry.isGroupSelected = groupSelection.contains(chat.id)
            entry.isReviewing = reviewing
            entry.isMasked = library.data.screenSharing
            entry.contextText = privacy.context(contexts[chat.id]?.displayText, isSharing: library.data.screenSharing) ?? ""
            entry.contextPath = privacy.context(contexts[chat.id]?.workingDirectory, isSharing: library.data.screenSharing) ?? ""
            if request != nil || reviewing { entry.status = .attention }
            else if [.working, .coding, .checking].contains(state) { entry.status = .running }
            else if state == .finished { entry.status = .completed }
            else if state == .interrupted { entry.status = .interrupted }
            else if state == .unknown { entry.status = .unknown }
            else { entry.status = .idle }
            return entry
        }
        dashboard.setScreenSharing(library.data.screenSharing)
        dashboard.update(entries: entries)
    }

    private func displayName(for sessionID: String) -> String {
        let original = library.data.labels[sessionID] ?? codexNames[sessionID.lowercased()] ?? "Чат без названия"
        return privacy.name(for: sessionID, original: original, isSharing: library.data.screenSharing)
    }

    private func statisticsSnapshot(_ period: TaskStatistics.Period) -> TaskStatistics.Snapshot {
        var names = codexNames
        for (id, name) in library.data.labels { names[id] = name }
        return statistics.snapshot(period: period, names: names, tokens: tokenReport,
            knownSessionIDs: Array(library.data.chats.keys), masked: library.data.screenSharing,
            now: option("--preview-scene") == "statistics" ? statisticsPreviewDate : Date())
    }

    private var statisticsPreviewDate: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(15 * 3600)
    }

    private func populateStatisticsPreview() {
        let now = statisticsPreviewDate
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        let third = "33333333-3333-4333-8333-333333333333"
        codexNames = [first: "JP-1234 Кеш запросов", second: "JP-1234 Проверка конкурентности", third: "JP-1420 Миграция API"]
        tokenReport = TaskTokenReader.Result(values: [first: 124800, second: 38200, third: 76500], status: .available,
            detail: "Выдуманные значения для демонстрации интерфейса.")
        for (index, id) in [first, second, third].enumerated() {
            let start = now.addingTimeInterval(-3600 + Double(index) * 500)
            let end = start.addingTimeInterval(Double(1200 + index * 240))
            let turn = "demo-\(index)"
            let chat = ChatSummary(id: id, turnID: turn, state: .working, startedAt: start, updatedAt: start)
            statistics.observe(event: CompanionEvent(event: "UserPromptSubmit", sessionID: id, turnID: turn,
                toolName: nil, toolUseID: nil, timestamp: start), accepted: true, current: chat)
            statistics.observe(event: CompanionEvent(event: "Stop", sessionID: id, turnID: turn,
                toolName: nil, toolUseID: nil, timestamp: end), accepted: true, current: chat)
        }
    }

    private func showStatistics() {
        let statisticsWindow = makeStatisticsWindow()
        dashboard.hide()
        settings?.hide()
        controller.dismissStateCard()
        lastTokenRead = .distantPast
        statisticsWindow.show()
        refreshStatistics(force: true)
    }

    private func refreshStatistics(force: Bool = false) {
        guard !displaySleeping, statisticsWindow?.isVisible == true else { return }
        if force || Date().timeIntervalSince(lastStatisticsRender) >= 5 {
            lastStatisticsRender = Date()
            if force { statisticsWindow?.refresh() } else { statisticsWindow?.refreshIfVisible() }
        }
        guard option("--preview") == nil, library.data.statisticsEnabled, !tokenReadInFlight,
              force || Date().timeIntervalSince(lastTokenRead) >= 15 else { return }
        tokenReadInFlight = true
        lastTokenRead = Date()
        let ids = Array(Set(Array(library.data.chats.keys) + statistics.sessionIDs).sorted().prefix(512))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = TaskTokenReader().read(sessionIDs: ids)
            DispatchQueue.main.async {
                guard let self else { return }
                self.tokenReadInFlight = false
                if self.library.data.statisticsEnabled { self.tokenReport = report }
                self.statisticsWindow?.refreshIfVisible()
            }
        }
    }

    private func refreshContexts() {
        guard option("--preview") == nil, dashboard.isVisible, !displaySleeping,
              !contextReadInFlight, Date().timeIntervalSince(lastContextRead) >= 5 else { return }
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
        guard option("--preview") == nil, !displaySleeping, !nameReadInFlight else { return }
        let ids = Array(sessionIDs.prefix(512))
        let membership = ids.sorted()
        let interval: TimeInterval = dashboard.isVisible || statisticsWindow?.isVisible == true ? 5 : 30
        guard membership != lastNameIDs || Date().timeIntervalSince(lastNameRead) >= interval else { return }
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
    Для готового файла или отчёта можешь сообщить проверки и прикрепить существующий локальный файл отдельной shell no-op командой:
    : codex-notch:result BASE64
    BASE64 — base64 от UTF-8 JSON {"checks":"passed|failed|notRun","path":"/абсолютный/путь/report.md"}. Поле path необязательно. Сначала создай файл. Передавай только честный итог запущенных проверок. Для file поддержаны документы/отчёты/изображения, исполняемые файлы и скрипты не открываются. После этого при необходимости отправь маркер review.
    Это no-op маркеры для локального hook PostToolUse. Используй прямой shell tool, без обёртки JavaScript, echo, дополнительных команд и перенаправлений. Не отправляй question для проверки разрешения, обычной работы или простого завершения хода. Не отправляй marker заранее. Если shell недоступен, просто продолжай общение; не утверждай, что сигнал был отправлен.
    """

    private func populatePreview() {
        let scene = option("--preview-scene") ?? "panel"
        let sharing = scene == "sharing"
        var entries = [
            DashboardEntry(id: "11111111-1111-4111-8111-111111111111", name: "Исправление кеша", stateText: "Ход завершён", elapsedText: "Ход: 7 мин", updatedText: "Последний сигнал: 12 с назад", unreadCount: 1, canRemindResult: true),
            DashboardEntry(id: "22222222-2222-4222-8222-222222222222", name: "Миграция API", stateText: "Пишет код", elapsedText: "Ход: 3 мин", updatedText: "Последний сигнал: 2 с назад", unreadCount: 0, canWatchDuration: true),
            DashboardEntry(id: "33333333-3333-4333-8333-333333333333", name: "Проверка сборки", stateText: "Ход завершён", elapsedText: "Ход: 42 с", updatedText: "Последний сигнал: 2 мин назад", unreadCount: 1, canRemindResult: true)
        ]
        entries[0].contextText = "backend · fix/cache · копия: cache-fix"
        entries[1].contextText = "backend · feature/api"
        entries[2].contextText = "frontend · main"
        entries[0].status = scene == "result" ? .attention : .completed
        entries[1].status = .running
        entries[2].status = .completed
        if scene == "result" {
            entries[0].isReviewing = true
            entries[0] = DashboardEntry(id: entries[0].id, name: entries[0].name, stateText: "На проверке", elapsedText: "Ход: 7 мин", updatedText: "Последний сигнал: 12 с назад", unreadCount: 1, canRemindResult: true, attentionText: "Требует проверки", resultID: "demo-result", resultText: "Агент сообщил: проверки пройдены", canOpenResult: true, isReviewing: true, contextText: "backend · fix/cache · копия: cache-fix", status: .attention)
        }
        if sharing {
            let mask = PrivacyPresentation(orderedSessionIDs: entries.map(\.id))
            for index in entries.indices {
                let original = entries[index]
                entries[index] = DashboardEntry(id: original.id, name: mask.name(for: original.id, original: original.name, isSharing: true), stateText: original.stateText, elapsedText: original.elapsedText, updatedText: original.updatedText, unreadCount: original.unreadCount, canRemindResult: original.canRemindResult, canWatchDuration: original.canWatchDuration, isMasked: true, status: original.status)
            }
        }
        dashboard.setScreenSharing(sharing)
        dashboard.update(entries: entries)
        dashboard.updateQuiet(status: scene == "group" ? "Тишина ещё 18 мин" : "Уведомления включены", active: scene == "group")
        dashboard.updateGroup(text: scene == "group" ? "Завершены 2 из 3" : nil, selectedCount: 0, hasGroup: scene == "group")
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? "\(total) с" : total < 3600 ? "\(total / 60) мин" : "\(total / 3600) ч \(total % 3600 / 60) мин"
    }

    private var lockDescriptor: Int32 = -1
    private func acquireInstanceLock() -> Bool {
        // Copies on the Desktop and in the installed folder share one live UI.
        // Test/demo runtimes explicitly supplied via the environment stay isolated.
        if ProcessInfo.processInfo.environment["CODEX_NOTCH_DATA_DIR"] == nil {
            let lock = FileManager.default.temporaryDirectory.appendingPathComponent("local.codex.notch.instance.lock")
            switch sharedInstance.acquire(url: lock) {
            case .acquired: break
            case .inUse:
                DistributedNotificationCenter.default().postNotificationName(showDashboardNotification, object: nil,
                    userInfo: nil, deliverImmediately: true)
                return false
            default: return false
            }
        }
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
