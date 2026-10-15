import Foundation

/// A presentation-only mask. Original names, paths, and IDs remain in local models
/// so opening a task still works; none of them are used as a masked fallback label.
struct PrivacyPresentation {
    private var ordinals: [String: Int] = [:]
    private var nextOrdinal = 1
    private static let maxSessions = 512

    static let genericNotice = "Есть обновление задач"
    static let genericDiagnostic = "Не удалось обновить локальные данные"

    init(orderedSessionIDs: [String] = []) {
        observe(sessionIDs: orderedSessionIDs)
    }

    /// Register known chats in their normal order once. Existing labels never shift
    /// when tasks are filtered, archived, reordered, or temporarily absent.
    mutating func observe(sessionIDs: [String]) {
        for id in sessionIDs.prefix(Self.maxSessions) {
            guard ordinals.count < Self.maxSessions,
                  let key = Self.key(id), ordinals[key] == nil else { continue }
            ordinals[key] = nextOrdinal
            nextOrdinal += 1
        }
    }

    func name(for sessionID: String, original: String, isSharing: Bool) -> String {
        guard isSharing else { return original }
        guard let key = Self.key(sessionID), let number = ordinals[key] else { return "Задача" }
        return "Задача \(number)"
    }

    func context(_ text: String?, isSharing: Bool) -> String? {
        isSharing ? nil : text
    }

    func diagnostic(_ text: String, isSharing: Bool) -> String {
        isSharing ? Self.genericDiagnostic : text
    }

    func notice(_ text: String, isSharing: Bool) -> String {
        isSharing ? Self.genericNotice : text
    }

    private static func key(_ raw: String) -> String? {
        guard raw.utf8.count == 36, let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
