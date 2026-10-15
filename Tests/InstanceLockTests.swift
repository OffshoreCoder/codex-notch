import Foundation
import Darwin

@main
struct InstanceLockTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexNotch-lock-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let path = directory.appendingPathComponent("shared.lock")
        let first = InstanceLock(), second = InstanceLock()
        expect(!first.isHeld && first.lockedURL == nil, "An unused object holds no descriptor")
        expect(first.acquire(url: path) == .acquired && first.isHeld, "First instance obtains a lock")
        expect(first.acquire(url: path) == .acquired, "Same instance reacquiring the same path is idempotent")
        expect(second.acquire(url: path) == .inUse && !second.isHeld, "Second instance cannot acquire the held inode")
        var metadata = stat()
        expect(lstat(path.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600,
               "Lock file is private even with normal process umask")
        expect(metadata.st_uid == getuid(), "Lock file belongs to this user")
        let isolated = directory.appendingPathComponent("isolated.lock")
        expect(first.acquire(url: isolated) == .holdingDifferentPath && first.lockedURL == path,
               "Acquiring another path never silently drops the existing lock")
        expect(second.acquire(url: isolated) == .acquired, "Different isolated runtime paths may run together")
        second.release()
        first.release()
        expect(!first.isHeld && first.lockedURL == nil, "Release clears local ownership")
        first.release()
        expect(second.acquire(url: path) == .acquired, "Another object can acquire after explicit release")
        second.release()
        expect(FileManager.default.fileExists(atPath: path.path), "Releasing keeps the shared inode in place")

        let lifetimePath = directory.appendingPathComponent("lifetime.lock")
        var lifetime: InstanceLock? = InstanceLock()
        expect(lifetime!.acquire(url: lifetimePath) == .acquired, "Lifetime fixture acquires its lock")
        lifetime = nil
        expect(first.acquire(url: lifetimePath) == .acquired, "Deinitialization releases the native lock")
        first.release()

        let target = directory.appendingPathComponent("target")
        try Data("unchanged".utf8).write(to: target)
        let link = directory.appendingPathComponent("symlink.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        expect(first.acquire(url: link) == .unsafePath, "A lock path may never follow a symlink")
        expect(try Data(contentsOf: target) == Data("unchanged".utf8), "A refused symlink never changes its target")
        expect(first.acquire(url: directory) == .unsafePath, "Directories cannot be locked as regular lock files")
        let fifo = directory.appendingPathComponent("pipe.lock")
        expect(mkfifo(fifo.path, mode_t(0o600)) == 0, "Nonregular fixture created without special permission")
        expect(first.acquire(url: fifo) == .unsafePath, "A FIFO is refused without blocking")
        let foreignUser: uid_t = getuid() == 0 ? 1 : 0
        expect(!InstanceLock.metadataIsSafe(mode: mode_t(S_IFREG) | 0o600, owner: foreignUser, userID: getuid()),
               "An inode owned by another user is refused, without needing chown in tests")
        expect(!InstanceLock.metadataIsSafe(mode: mode_t(S_IFLNK) | 0o600, owner: getuid(), userID: getuid()),
               "Owned symlinks are still unsafe")
        expect(first.acquire(url: URL(string: "https://example.invalid/lock")!) == .unsafePath,
               "Only local file URLs can name a lock")
        print("PASS: Instance locks (\(checks) checks)")
    }
}
