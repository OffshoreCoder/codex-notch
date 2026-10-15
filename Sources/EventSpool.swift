import Foundation

struct EventSpool {
    let directory: URL
    private let fm = FileManager.default
    static let limit = 256

    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_NOTCH_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let bundle = Bundle.main.bundleURL
        let root = bundle.pathExtension == "app" ? bundle.deletingLastPathComponent()
            : URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        return root.appendingPathComponent(".codex-notch-runtime", isDirectory: true)
    }

    func prepare() throws {
        // Never follow a pre-existing runtime symlink or chmod somebody else's directory.
        if fm.fileExists(atPath: directory.path) {
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }

    func append(_ event: CompanionEvent) throws {
        try prepare()
        let data = try JSONEncoder().encode(event)
        let name = String(format: "%020.0f", event.timestamp.timeIntervalSince1970 * 1_000_000)
            + "-" + UUID().uuidString + ".event"
        let target = directory.appendingPathComponent(name)
        // The containing directory is private before atomic creation (also with umask 000).
        try data.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let files = try eventFiles()
        if files.count > Self.limit {
            for old in files.prefix(files.count - Self.limit) { try? fm.removeItem(at: old) }
        }
    }

    func drain() -> [CompanionEvent] {
        guard let files = try? eventFiles() else { return [] }
        var events: [CompanionEvent] = []
        for file in files {
            if let attributes = try? fm.attributesOfItem(atPath: file.path),
               attributes[.type] as? FileAttributeType == .typeRegular,
               let size = attributes[.size] as? NSNumber, size.intValue <= 4096,
               let data = try? Data(contentsOf: file),
               let event = try? JSONDecoder().decode(CompanionEvent.self, from: data) {
                events.append(event)
            }
            try? fm.removeItem(at: file)
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    private func eventFiles() throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "event" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
