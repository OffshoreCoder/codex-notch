import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local diagnostics only. A correct configuration is not proof of hook trust or delivery.
enum IntegrationHealth {
    enum Status: String {
        case ok, warning, failure, unknown
    }

    struct Check {
        let id: String
        let title: String
        let detail: String
        let status: Status
    }

    struct Report {
        let checks: [Check]

        var hasFailures: Bool { checks.contains { $0.status == .failure } }
        var summary: String {
            if hasFailures { return "Обнаружена локальная проблема подключения" }
            if checks.contains(where: { $0.status == .warning }) {
                return "Есть замечания; доставка событий ещё требует проверки"
            }
            return "Локальные проверки пройдены; доверие и доставку подтверждает Codex"
        }
    }

    private static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                                 "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
    private static let marker = " --hook --codex-notch"

    static func check(hooksURL: URL, executableURL: URL, spoolDirectory: URL,
                      runSelfTest: Bool = false) -> Report {
        var checks = [executableCheck(executableURL), hooksCheck(hooksURL, executableURL: executableURL)]
        let selfTestCheck: Check
        if runSelfTest {
            do {
                try selfTest(in: spoolDirectory)
                selfTestCheck = Check(id: "self-test", title: "Проверка записи и чтения", detail:
                    "Локальный файл события записан и прочитан. Тестовые файлы удалены. Доставку из Codex этот тест не подтверждает.", status: .ok)
            } catch {
                selfTestCheck = Check(id: "self-test", title: "Проверка записи и чтения", detail:
                    "Локальная проверка не прошла: \(error.localizedDescription)", status: .failure)
            }
        } else {
            selfTestCheck = Check(id: "self-test", title: "Проверка записи и чтения", detail:
                "Не запускалась. Проверка создаёт отдельный временный файл и не читает очередь реальных событий.", status: .unknown)
        }
        // Report the current state, including a directory just created by the test.
        checks.append(spoolCheck(spoolDirectory))
        checks.append(selfTestCheck)
        checks.append(Check(id: "hook-trust", title: "Доверие Codex к обработчикам", detail:
            "Приложение не может проверить доверие. Проверьте обработчики CodexNotch в /hooks; локальный тест не заменяет реальное событие из нового чата.", status: .unknown))
        return Report(checks: checks)
    }

    private static func executableCheck(_ url: URL) -> Check {
        do {
            try validateLocalURL(url)
            let info = try attributesWithoutFollowingLink(url)
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw HealthError("По пути приложения должен находиться обычный файл, а не ссылка или каталог.")
            }
            guard access(url.path, X_OK) == 0 else { throw HealthError("Файл приложения нельзя выполнить.") }
            return Check(id: "executable", title: "Файл приложения", detail: "Исполняемый файл доступен.", status: .ok)
        } catch {
            return Check(id: "executable", title: "Файл приложения", detail: error.localizedDescription, status: .failure)
        }
    }

    private static func hooksCheck(_ url: URL, executableURL: URL) -> Check {
        do {
            try validateLocalURL(executableURL)
            guard let data = try readConfiguration(url) else {
                return Check(id: "hooks", title: "Настройка hooks", detail:
                    "hooks.json пока отсутствует. Подключите обработчики; отсутствие файла не доказывает сбой Codex.", status: .warning)
            }
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HealthError("hooks.json должен содержать JSON-объект.")
            }
            if document["hooks"] != nil && !(document["hooks"] is [String: Any]) {
                throw HealthError("Поле hooks должно содержать JSON-объект.")
            }
            let hooks = document["hooks"] as? [String: Any] ?? [:]
            let expectedCommand = "'" + executableURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'" + marker
            var incomplete: [String] = []
            var duplicate: [String] = []
            for event in events {
                if hooks[event] != nil && !(hooks[event] is [[String: Any]]) {
                    throw HealthError("Обработчики \(event) должны быть массивом групп.")
                }
                let groups = hooks[event] as? [[String: Any]] ?? []
                var valid = 0
                var managed = 0
                for group in groups {
                    guard let handlers = group["hooks"] as? [[String: Any]] else {
                        throw HealthError("Группа \(event) должна содержать массив hooks.")
                    }
                    let matcher = group["matcher"] as? String
                    let unfiltered = matcher == nil || matcher == "*" || matcher == ""
                    for handler in handlers {
                        guard handler["type"] as? String == "command",
                              let command = handler["command"] as? String,
                              command.hasSuffix(marker) else { continue }
                        managed += 1
                        if command == expectedCommand && unfiltered && handler["async"] as? Bool != true {
                            valid += 1
                        }
                    }
                }
                if valid == 0 { incomplete.append(event) }
                if managed > 1 { duplicate.append(event) }
            }
            var notices: [String] = []
            if !incomplete.isEmpty {
                notices.append("Нет наблюдателя для текущего пути приложения без фильтров: " + incomplete.joined(separator: ", ") + ".")
            }
            if !duplicate.isEmpty {
                notices.append("Повторные обработчики: " + duplicate.joined(separator: ", ") + ". Переподключение оставит по одному обработчику приложения.")
            }
            if !notices.isEmpty {
                return Check(id: "hooks", title: "Настройка hooks", detail: notices.joined(separator: " "), status: .warning)
            }
            return Check(id: "hooks", title: "Настройка hooks", detail:
                "Все 8 наблюдателей указывают на текущий файл приложения. Настройки не изменялись.", status: .ok)
        } catch {
            return Check(id: "hooks", title: "Настройка hooks", detail:
                "Настройки нельзя проверить: \(error.localizedDescription)", status: .failure)
        }
    }

    private static func spoolCheck(_ url: URL) -> Check {
        do {
            try validateLocalURL(url)
            guard let info = try optionalAttributes(url) else {
                return Check(id: "spool", title: "Каталог локальных событий", detail:
                    "Пока не создан. Его создаст первое событие или локальная проверка записи.", status: .warning)
            }
            try validateDirectory(info)
            guard info.st_mode & mode_t(0o077) == 0 else {
                return Check(id: "spool", title: "Каталог локальных событий", detail:
                    "Каталог доступен другим пользователям. Новые события обычно выставляют права 0700; проверьте расположение каталога.", status: .warning)
            }
            return Check(id: "spool", title: "Каталог локальных событий", detail:
                "Каталог принадлежит текущему пользователю и закрыт для остальных.", status: .ok)
        } catch {
            return Check(id: "spool", title: "Каталог локальных событий", detail:
                error.localizedDescription, status: .failure)
        }
    }

    private static func selfTest(in directory: URL) throws {
        try validateLocalURL(directory)
        if try optionalAttributes(directory) == nil {
            guard mkdir(directory.path, mode_t(0o700)) == 0 || errno == EEXIST else {
                throw systemError("Не удалось создать каталог событий")
            }
        }
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD != -1 else { throw systemError("Не удалось открыть каталог событий без перехода по ссылке") }
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0 else { throw systemError("Не удалось проверить каталог событий") }
        try validateDirectory(rootInfo)

        // Descriptor-relative operations stay inside the inspected directory even if
        // its path is renamed. The live .event queue is never enumerated or consumed.
        let temporaryName = ".health-" + UUID().uuidString
        guard mkdirat(rootFD, temporaryName, mode_t(0o700)) == 0 else { throw systemError("Не удалось создать каталог проверки") }
        defer { _ = unlinkat(rootFD, temporaryName, AT_REMOVEDIR) }
        let testFD = openat(rootFD, temporaryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard testFD != -1 else { throw systemError("Не удалось открыть каталог проверки") }
        defer { close(testFD) }
        let filename = "roundtrip.health"
        let fd = openat(testFD, filename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd != -1 else { throw systemError("Не удалось создать файл проверки") }
        defer { _ = unlinkat(testFD, filename, 0) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw systemError("Не удалось защитить файл проверки") }
        let event = CompanionEvent(event: "SessionStart", sessionID: "health-check-" + UUID().uuidString,
                                   turnID: nil, toolName: nil, toolUseID: nil, timestamp: Date())
        let data = try JSONEncoder().encode(event)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.seek(toOffset: 0)
        let readBack = try file.readToEnd() ?? Data()
        let decoded = try JSONDecoder().decode(CompanionEvent.self, from: readBack)
        guard readBack == data && decoded.event == event.event && decoded.sessionID == event.sessionID else {
            throw HealthError("Прочитанное событие отличается от записанного.")
        }
    }

    private static func readConfiguration(_ url: URL) throws -> Data? {
        try validateLocalURL(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd == -1 {
            if errno == ENOENT { return nil }
            throw systemError("Не удалось прочитать hooks.json без перехода по ссылке")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError("Не удалось проверить hooks.json") }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= 1_048_576 else {
            throw HealthError("hooks.json должен быть обычным файлом размером не более 1 МБ.")
        }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw HealthError("hooks.json превышает 1 МБ.") }
        return data
    }

    private static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw HealthError("Для проверки нужен абсолютный локальный путь.")
        }
    }

    private static func optionalAttributes(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw systemError("Не удалось проверить локальный путь")
    }

    private static func attributesWithoutFollowingLink(_ url: URL) throws -> stat {
        guard let info = try optionalAttributes(url) else { throw HealthError("Файл приложения отсутствует.") }
        return info
    }

    private static func validateDirectory(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid() else {
            throw HealthError("Каталог событий должен принадлежать текущему пользователю и быть обычным каталогом, а не ссылкой.")
        }
    }

    private static func systemError(_ operation: String) -> HealthError {
        HealthError(operation + ": " + String(cString: strerror(errno)))
    }

    private struct HealthError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
