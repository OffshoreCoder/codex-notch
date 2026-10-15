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
        if option("--preview") == nil {
            for event in spool.drain() {
                model.receive(event)
                if let result = model.completion(for: event), library.record(result) {
                    controller.notify(title: "Ход завершён", sessionID: result.sessionID)
                }
            }
        }
        let live = model.snapshot()
        let snapshot = demo.map {
            CompanionSnapshot(state: $0, sessionID: nil, activeCount: [.working, .coding, .checking].contains($0) ? 1 : 0, updatedAt: Date())
        } ?? live
        controller.update(snapshot)
        controller.updateQueue(library.data.completions, error: library.error)
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
