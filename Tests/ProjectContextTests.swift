import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct ProjectContextTests {
    private static var checks = 0
    private static let fm = FileManager.default
    private static let reader = ProjectContextReader()

    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("CodexNotchContextTests-" + UUID().uuidString, isDirectory: true)
        try directory(root)
        defer { try? fm.removeItem(at: root) }
        try paths(root)
        try repository(root)
        try detachedAndInvalidRefs(root)
        try linkedWorktree(root)
        try safety(root)
        print("PASS: ProjectContext (\(checks) checks)")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(message: message) }
    }

    private static func directory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private static func write(_ text: String, _ url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func git(_ root: URL, head: String = "ref: refs/heads/main\n") throws -> URL {
        let metadata = root.appendingPathComponent(".git", isDirectory: true)
        try directory(metadata)
        try write(head, metadata.appendingPathComponent("HEAD"))
        return metadata
    }

    private static func paths(_ root: URL) throws {
        try expect(ProjectContextReader.sanitizeWorkingDirectory("relative/repo") == nil, "Relative paths must be rejected")
        try expect(ProjectContextReader.sanitizeWorkingDirectory("file:///repo") == nil, "URL strings must not become local paths")
        try expect(ProjectContextReader.sanitizeWorkingDirectory("//server/repo") == nil, "Double-slash network-style paths must be rejected")
        try expect(ProjectContextReader.sanitizeWorkingDirectory("/repo\nsecret") == nil, "Control characters must be rejected")
        try expect(ProjectContextReader.sanitizeWorkingDirectory("/repo\u{202E}evil") == nil, "Bidi formatting controls must be rejected")
        try expect(ProjectContextReader.sanitizeWorkingDirectory("/" + String(repeating: "x", count: 4096)) == nil, "Path decoding must be bounded")
        try expect(ProjectContextReader.sanitizeWorkingDirectory("/one/../two/./repo") == "/two/repo", "Dot segments must be normalized")
        try expect(ProjectContextReader.sanitizeWorkingDirectory("/private/tmp/repo") == "/private/tmp/repo", "Lexical normalization must not rewrite safe macOS paths through symlink aliases")
        let project = root.appendingPathComponent("Plain project", isDirectory: true)
        try directory(project)
        let context = reader.read(workingDirectory: project.path)
        try expect(context?.projectName == "Plain project" && context?.branchName == nil, "Non-Git folders still provide a project label")
        try expect(context?.workingDirectory == project.path && context?.isWorktree == false, "Context retains only its validated working directory")
        try expect(reader.read(workingDirectory: project.appendingPathComponent("missing").path) == nil, "Missing directories fail without creation")
        try expect(reader.read(workingDirectory: "/")?.projectName == "Файлы", "Root folder has a useful generic label")
    }

    private static func repository(_ root: URL) throws {
        let project = root.appendingPathComponent("backend", isDirectory: true)
        let metadata = try git(project, head: "ref: refs/heads/fix/cache\n")
        let nested = project.appendingPathComponent("Sources/cache", isDirectory: true)
        try directory(nested)
        // A branch can be unborn: do not require or read its ref, index, config, or code.
        try write("private-remote-sentinel", metadata.appendingPathComponent("config"))
        try write("private-code-sentinel", nested.appendingPathComponent("Secret.swift"))
        let filesBefore = try fm.subpathsOfDirectory(atPath: project.path).sorted()
        let headBefore = try Data(contentsOf: metadata.appendingPathComponent("HEAD"))
        let context = reader.read(workingDirectory: nested.path)
        try expect(context?.projectName == "backend", "Nested cwd must use the nearest repository root name")
        try expect(context?.branchName == "fix/cache", "HEAD branch must be shown without resolving Git objects")
        try expect(context?.workingCopyName == nil && context?.isWorktree == false, "Ordinary checkout must not be called a linked worktree")
        try expect(context?.displayText == "backend · fix/cache", "Developer context must be concise and legible")
        try expect(try fm.subpathsOfDirectory(atPath: project.path).sorted() == filesBefore, "Reader must not create files")
        try expect(try Data(contentsOf: metadata.appendingPathComponent("HEAD")) == headBefore, "Reader must leave Git metadata unchanged")
        try write("ref: refs/heads/review/ui\n", metadata.appendingPathComponent("HEAD"))
        try expect(reader.read(workingDirectory: nested.path)?.branchName == "review/ui", "Repeated reads must observe branch changes")
        let nestedRepo = nested.appendingPathComponent("vendor", isDirectory: true)
        _ = try git(nestedRepo, head: "ref: refs/heads/dependency\n")
        try expect(reader.read(workingDirectory: nestedRepo.path)?.branchName == "dependency", "Nested repositories must not inherit parent branch")
        try fm.removeItem(at: nestedRepo.appendingPathComponent(".git"))
        try write("not git metadata", nestedRepo.appendingPathComponent(".git"))
        try expect(reader.read(workingDirectory: nestedRepo.path)?.branchName == nil, "Malformed nearest marker must not silently use an ancestor repository")
    }

    private static func detachedAndInvalidRefs(_ root: URL) throws {
        let project = root.appendingPathComponent("refs", isDirectory: true)
        let metadata = try git(project)
        try write(String(repeating: "a", count: 40) + "\n", metadata.appendingPathComponent("HEAD"))
        try expect(reader.read(workingDirectory: project.path)?.branchName == "HEAD · aaaaaaaa", "Detached HEAD must show a bounded commit prefix")
        try write(String(repeating: "B", count: 64) + "\n", metadata.appendingPathComponent("HEAD"))
        try expect(reader.read(workingDirectory: project.path)?.branchName == "HEAD · bbbbbbbb", "SHA-256 detached HEAD must be recognized")
        for malformed in ["ref: refs/heads/", "ref: refs/heads/../secret", "ref: refs/heads/fix cache", "ref: refs/heads/a@{b", "ref: refs/heads/a.lock", "ref: refs/heads/a//b", "ref: refs/heads/.hidden", "ref: refs/heads/a\u{202E}b", "ref: refs/remotes/origin/main", "private-content-sentinel", "ref: refs/heads/one\nprivate-content-sentinel"] {
            try write(malformed + "\n", metadata.appendingPathComponent("HEAD"))
            let context = reader.read(workingDirectory: project.path)
            try expect(context?.branchName == nil && context?.displayText == "refs", "Malformed or unsupported HEAD must fail without exposing its content")
        }
        try write("ref: refs/heads/исправление/кеш\r\n", metadata.appendingPathComponent("HEAD"))
        try expect(reader.read(workingDirectory: project.path)?.branchName == "исправление/кеш", "Unicode branch names and CRLF metadata remain usable")
    }

    private static func linkedWorktree(_ root: URL) throws {
        let main = root.appendingPathComponent("service", isDirectory: true)
        let common = try git(main)
        let copy = root.appendingPathComponent("service-fix", isDirectory: true)
        try directory(copy.appendingPathComponent("src", isDirectory: true))
        let metadata = common.appendingPathComponent("worktrees/service-fix", isDirectory: true)
        try directory(metadata)
        try write("gitdir: " + metadata.path + "\n", copy.appendingPathComponent(".git"))
        try write("../..\n", metadata.appendingPathComponent("commondir"))
        try write(copy.appendingPathComponent(".git").path + "\n", metadata.appendingPathComponent("gitdir"))
        try write("ref: refs/heads/fix/race\n", metadata.appendingPathComponent("HEAD"))
        let context = reader.read(workingDirectory: copy.appendingPathComponent("src").path)
        try expect(context?.projectName == "service", "Worktree must retain its shared project identity")
        try expect(context?.branchName == "fix/race", "Worktree must use its own HEAD rather than main HEAD")
        try expect(context?.workingCopyName == "service-fix" && context?.isWorktree == true, "Linked copy must have a distinguishable label")
        try expect(context?.displayText == "service · fix/race · копия: service-fix", "Worktree context must be human-readable")
        try write("gitdir: ../service/.git/worktrees/service-fix\n", copy.appendingPathComponent(".git"))
        try expect(reader.read(workingDirectory: copy.path)?.isWorktree == true, "Relative gitdir pointers must be resolved against their marker directory")
        try write("/stale/other/.git\n", metadata.appendingPathComponent("gitdir"))
        try expect(reader.read(workingDirectory: copy.path)?.branchName == nil, "Stale reciprocal worktree pointers must fail closed")
        try write(copy.appendingPathComponent(".git").path + "\n", metadata.appendingPathComponent("gitdir"))
        try write("../../../../\n", metadata.appendingPathComponent("commondir"))
        try expect(reader.read(workingDirectory: copy.path)?.branchName == nil, "Arbitrary commondir traversal outside the standard worktree layout must be refused")
    }

    private static func safety(_ root: URL) throws {
        let project = root.appendingPathComponent("safe", isDirectory: true)
        let metadata = try git(project)
        let head = metadata.appendingPathComponent("HEAD")
        let target = root.appendingPathComponent("private-head")
        try write("ref: refs/heads/private-sentinel\n", target)
        try fm.removeItem(at: head)
        try fm.createSymbolicLink(at: head, withDestinationURL: target)
        try expect(reader.read(workingDirectory: project.path)?.branchName == nil, "HEAD symlinks must not be read")
        try fm.removeItem(at: head)
        try expect(mkfifo(head.path, mode_t(0o600)) == 0, "FIFO fixture must exist")
        let start = Date()
        try expect(reader.read(workingDirectory: project.path)?.branchName == nil, "Special metadata files must fail without blocking")
        try expect(Date().timeIntervalSince(start) < 1, "FIFO metadata must not block the caller")
        try fm.removeItem(at: head)
        try write(String(repeating: "x", count: 4097), head)
        try expect(reader.read(workingDirectory: project.path)?.branchName == nil, "Metadata read must be bounded")
        try write("ref: refs/heads/main\n", head)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: project)
        try expect(reader.read(workingDirectory: alias.path) == nil, "Symlink working directories must not redirect reads")
        let child = project.appendingPathComponent("child", isDirectory: true)
        try directory(child)
        try expect(reader.read(workingDirectory: alias.appendingPathComponent("child").path) == nil, "Symlinks in parent paths must not redirect reads")
        let external = root.appendingPathComponent("external", isDirectory: true)
        try directory(external)
        try fm.createSymbolicLink(at: external.appendingPathComponent(".git"), withDestinationURL: metadata)
        try expect(reader.read(workingDirectory: external.path)?.branchName == nil, ".git directory symlinks must not redirect metadata reads")
        let marker = external.appendingPathComponent(".git")
        try fm.removeItem(at: marker)
        try expect(mkfifo(marker.path, mode_t(0o600)) == 0, "FIFO marker fixture must exist")
        try expect(reader.read(workingDirectory: external.path)?.branchName == nil, "Special .git markers must not be opened")
        try fm.removeItem(at: marker)
        try write("gitdir: " + metadata.path + "\n", marker)
        try expect(reader.read(workingDirectory: external.path)?.branchName == "main", "Separate Git directories may supply their explicitly referenced HEAD")
        try write("gitdir: " + metadata.path + "\nextra-line\n", marker)
        try expect(reader.read(workingDirectory: external.path)?.branchName == nil, "Malformed multi-line gitdir pointers must be rejected")
        try fm.removeItem(at: marker)
        try Data([0xff, 0xfe]).write(to: marker)
        try expect(reader.read(workingDirectory: external.path)?.branchName == nil, "Non-UTF8 metadata must fail safely")
    }

    private struct Failure: Error { let message: String }
}
