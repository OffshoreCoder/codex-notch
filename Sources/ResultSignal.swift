import Foundation

/// Explicit agent-supplied metadata. A finished turn alone never implies passing checks.
enum CheckOutcome: String, Codable { case passed, failed, notRun }
struct TurnResult: Codable, Equatable, Identifiable {
    let sessionID: String
    let turnID: String
    let path: String?
    let checks: CheckOutcome
    let timestamp: Date
    var id: String { sessionID + "|" + turnID }
    var checkText: String {
        switch checks {
        case .passed: return "Агент сообщил: проверки пройдены"
        case .failed: return "Агент сообщил: проверки не прошли"
        case .notRun: return "Агент сообщил: проверки не запускались"
        }
    }
}

enum ResultSignal {
    /// An exact shell no-op followed by one base64 JSON object, never a shell parser.
    static func parse(command: String, sessionID: String, turnID: String, now: Date = Date()) -> TurnResult? {
        let prefix = ": codex-notch:result "
        guard command.hasPrefix(prefix), command.utf8.count <= 6000 else { return nil }
        let encoded = String(command.dropFirst(prefix.count))
        guard !encoded.isEmpty, encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43,47,61].contains($0) }),
              let data = Data(base64Encoded: encoded), data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["path", "checks"]),
              let raw = object["checks"] as? String, let checks = CheckOutcome(rawValue: raw) else { return nil }
        var path: String?
        if let value = object["path"] {
            guard let text = value as? String, let valid = safePath(text) else { return nil }
            path = valid
        }
        return TurnResult(sessionID: sessionID, turnID: turnID, path: path, checks: checks, timestamp: now)
    }
    static func safePath(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= 2048,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.split(separator: "/").contains("..") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Opening an attachment must never execute an application, script, shortcut or package.
        let allowed: Set<String> = ["md", "txt", "log", "json", "csv", "html", "pdf", "png", "jpg", "jpeg", "webp", "svg", "pptx", "xlsx", "docx", "diff", "patch"]
        guard allowed.contains(url.pathExtension.lowercased()),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        return url.path
    }
}
