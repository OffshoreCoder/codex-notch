import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Small, local context derived from a working directory and Git metadata only.
/// No project contents, Git configuration, remotes, index, or commit objects are read.
struct ProjectContext: Equatable {
    let workingDirectory: String
    let projectName: String
    let branchName: String?
    let workingCopyName: String?
    let isWorktree: Bool

    var displayText: String {
        [projectName, branchName, workingCopyName.map { "копия: " + $0 }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct ProjectContextReader {
    private static let maxPathBytes = 4096
    private static let maxMetadataBytes = 4096
    private static let maxAncestors = 64

    /// Keep paths out of the event model unless they are bounded, absolute local paths.
    /// This validates syntax; `read` additionally requires existing non-symlink directories.
    static func sanitizeWorkingDirectory(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), !raw.hasPrefix("//"), raw.utf8.count <= maxPathBytes,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // Foundation standardization rewrites /private/tmp to the /tmp symlink on macOS.
        // Normalize dot segments lexically so descriptor traversal keeps the exact safe path.
        var components: [Substring] = []
        for component in raw.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }

    func read(workingDirectory raw: String) -> ProjectContext? {
        guard let path = Self.sanitizeWorkingDirectory(raw), let initial = Self.openDirectory(path) else { return nil }
        close(initial)
        var root = URL(fileURLWithPath: path, isDirectory: true)
        for _ in 0..<Self.maxAncestors {
            guard let directory = Self.openDirectory(root.path) else { return nil }
            var info = stat()
            let markerStatus = fstatat(directory, ".git", &info, AT_SYMLINK_NOFOLLOW)
            let markerError = errno
            close(directory)
            if markerStatus == 0 {
                let kind = info.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFDIR) {
                    let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
                    return makeContext(path: path, root: root, gitDirectory: gitDirectory)
                }
                if kind == mode_t(S_IFREG),
                   let marker = Self.readMetadata(root.appendingPathComponent(".git")),
                   marker.hasPrefix("gitdir: "),
                   let gitPath = Self.metadataPath(String(marker.dropFirst(8)), relativeTo: root) {
                    return makeContext(path: path, root: root, gitDirectory: gitPath)
                }
                // A malformed nearest marker must not resolve to a different parent repository.
                return plainContext(path: path)
            }
            if markerStatus != 0 && markerError != ENOENT { return plainContext(path: path) }
            let parent = root.deletingLastPathComponent()
            if parent.path == root.path { break }
            root = parent
        }
        return plainContext(path: path)
    }

    private func makeContext(path: String, root: URL, gitDirectory: URL) -> ProjectContext {
        guard let head = Self.readMetadata(gitDirectory.appendingPathComponent("HEAD")),
              let branch = Self.branch(from: head) else { return plainContext(path: path) }
        var project = Self.displayName(root.lastPathComponent)
        var copy: String?
        var worktree = false
        if let commonMarker = Self.readMetadata(gitDirectory.appendingPathComponent("commondir")) {
            // Only accept the standard linked-worktree layout, with a reciprocal pointer.
            guard let common = Self.metadataPath(commonMarker, relativeTo: gitDirectory),
                  gitDirectory.deletingLastPathComponent().lastPathComponent == "worktrees",
                  gitDirectory.deletingLastPathComponent().deletingLastPathComponent().path == common.path,
                  let backlink = Self.readMetadata(gitDirectory.appendingPathComponent("gitdir")),
                  let marker = Self.metadataPath(backlink, relativeTo: gitDirectory),
                  marker.path == root.appendingPathComponent(".git").path,
                  let commonFD = Self.openDirectory(common.path) else {
                return plainContext(path: path)
            }
            close(commonFD)
            worktree = true
            copy = Self.displayName(root.lastPathComponent)
            if common.lastPathComponent == ".git" {
                project = Self.displayName(common.deletingLastPathComponent().lastPathComponent)
            }
        }
        return ProjectContext(workingDirectory: path, projectName: project, branchName: branch,
                              workingCopyName: copy, isWorktree: worktree)
    }

    private func plainContext(path: String) -> ProjectContext {
        ProjectContext(workingDirectory: path,
                       projectName: Self.displayName(URL(fileURLWithPath: path).lastPathComponent),
                       branchName: nil, workingCopyName: nil, isWorktree: false)
    }

    private static func displayName(_ raw: String) -> String {
        let clean = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "/" ? "Файлы" : String(clean.prefix(80))
    }

    private static func branch(from head: String) -> String? {
        if head.hasPrefix("ref: refs/heads/") {
            let branch = String(head.dropFirst(16))
            let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
                .union(CharacterSet(charactersIn: "~^:?*[\\"))
            let parts = branch.split(separator: "/", omittingEmptySubsequences: false)
            guard !branch.isEmpty, branch.utf8.count <= 1024,
                  !branch.unicodeScalars.contains(where: { forbidden.contains($0) }),
                  !branch.contains(".."), !branch.contains("@{"), branch != "@",
                  parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") && !$0.hasSuffix(".") }) else { return nil }
            return String(branch.prefix(120))
        }
        if (head.utf8.count == 40 || head.utf8.count == 64),
           head.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            return "HEAD · " + head.prefix(8).lowercased()
        }
        return nil
    }

    private static func metadataPath(_ raw: String, relativeTo base: URL) -> URL? {
        guard !raw.isEmpty, raw.utf8.count <= maxPathBytes,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !raw.hasPrefix("//") else { return nil }
        let path = raw.hasPrefix("/") ? raw : base.path + "/" + raw
        guard let clean = sanitizeWorkingDirectory(path) else { return nil }
        return URL(fileURLWithPath: clean, isDirectory: true)
    }

    /// Open every directory component relative to a descriptor. No metadata read follows
    /// a symlink, including symlinks in parent paths, and special files cannot block us.
    private static func openDirectory(_ path: String) -> Int32? {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in path.split(separator: "/") {
            let next = component.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        return descriptor
    }

    private static func readMetadata(_ url: URL) -> String? {
        guard let directory = openDirectory(url.deletingLastPathComponent().path) else { return nil }
        defer { close(directory) }
        let descriptor = url.lastPathComponent.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= maxMetadataBytes,
              var bytes = try? file.read(upToCount: maxMetadataBytes + 1), bytes.count <= maxMetadataBytes else { return nil }
        if bytes.last == 10 { bytes.removeLast() }
        if bytes.last == 13 { bytes.removeLast() }
        guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
}
