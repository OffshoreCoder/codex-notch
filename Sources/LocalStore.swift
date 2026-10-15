import Foundation

struct CompletedTurn: Codable, Equatable, Identifiable {
    let sessionID: String
    let turnID: String
    let startedAt: Date?
    let finishedAt: Date
    var id: String { sessionID + "|" + turnID }
}

struct LocalData: Codable {
    var completions: [CompletedTurn] = []
    var seenCompletions: [String] = []
    var chats: [String: ChatSummary] = [:]
    var labels: [String: String] = [:]

    init() {}
    enum CodingKeys: String, CodingKey { case completions, seenCompletions, chats, labels }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completions = try c.decodeIfPresent([CompletedTurn].self, forKey: .completions) ?? []
        seenCompletions = try c.decodeIfPresent([String].self, forKey: .seenCompletions) ?? []
        chats = try c.decodeIfPresent([String: ChatSummary].self, forKey: .chats) ?? [:]
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}

/// Deliberately stores metadata only. A corrupt file is left untouched for recovery.
final class LocalStore {
    private(set) var data = LocalData()
    private(set) var error: String?
    private let directory: URL
    private var canWrite = true
    private var url: URL { directory.appendingPathComponent("library.json") }

    init(directory: URL) {
        self.directory = directory
        do {
            try EventSpool(directory: directory).prepare()
            if FileManager.default.fileExists(atPath: url.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 4 * 1024 * 1024 else {
                    throw CocoaError(.fileReadNoPermission)
                }
                data = try JSONDecoder().decode(LocalData.self, from: Data(contentsOf: url))
            }
        } catch {
            self.error = "Локальная очередь недоступна: \(error.localizedDescription)"
            canWrite = false
        }
    }

    @discardableResult func record(_ completion: CompletedTurn) -> Bool {
        guard !data.seenCompletions.contains(completion.id) else { return false }
        update {
            $0.completions.append(completion)
            $0.completions = Array($0.completions.suffix(512))
            $0.seenCompletions.append(completion.id)
            $0.seenCompletions = Array($0.seenCompletions.suffix(4096))
        }
        return true
    }

    func remember(_ chats: [ChatSummary]) {
        update { data in
            for chat in chats { data.chats[chat.id] = chat }
            if data.chats.count > 256 {
                let keep = data.chats.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(256)
                data.chats = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
                data.labels = data.labels.filter { data.chats[$0.key] != nil }
            }
        }
    }

    func rename(_ sessionID: String, to name: String) {
        let label = String(name.filter { !$0.isNewline && !$0.isASCIIControl }.prefix(80)).trimmingCharacters(in: .whitespaces)
        update { $0.labels[sessionID] = label.isEmpty ? nil : label }
    }
    func name(for sessionID: String) -> String { data.labels[sessionID] ?? "Чат " + String(sessionID.prefix(8)) }
    func acknowledgeChat(_ sessionID: String) { update { $0.completions.removeAll { $0.sessionID == sessionID } } }

    func acknowledge(_ id: String) { update { $0.completions.removeAll { $0.id == id } } }
    func acknowledgeAll() { update { $0.completions.removeAll() } }

    func update(_ change: (inout LocalData) -> Void) {
        change(&data)
        guard canWrite else { return }
        do {
            try EventSpool(directory: directory).prepare()
            // Refuse a replaced symlink instead of modifying its target.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               attrs[.type] as? FileAttributeType != .typeRegular { throw CocoaError(.fileWriteNoPermission) }
            try JSONEncoder().encode(data).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            error = nil
        } catch { self.error = "Не удалось сохранить очередь: \(error.localizedDescription)" }
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
