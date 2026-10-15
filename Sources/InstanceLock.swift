import Foundation
import Darwin

/// A nonblocking advisory lock for one local app instance. The lock file stays
/// in place after release: unlinking it could let two processes lock two inodes.
/// Call from one serial context; holding this object retains the native lock.
final class InstanceLock {
    enum Acquisition: Equatable {
        case acquired
        case inUse
        case unsafePath
        case holdingDifferentPath
        case failed(Int32)
    }

    private var descriptor: Int32 = -1
    private(set) var lockedURL: URL?
    var isHeld: Bool { descriptor >= 0 }

    deinit { release() }

    @discardableResult
    func acquire(url: URL) -> Acquisition {
        guard url.isFileURL, !url.path.isEmpty, !url.path.utf8.contains(0) else { return .unsafePath }
        let target = url.standardizedFileURL
        if isHeld { return target == lockedURL ? .acquired : .holdingDifferentPath }

        // Diagnose unsafe existing paths before open. fstat below repeats this
        // check on the opened inode, closing the usual preflight/open race.
        var before = stat()
        if lstat(target.path, &before) == 0 {
            guard Self.metadataIsSafe(mode: before.st_mode, owner: before.st_uid, userID: getuid()) else {
                return .unsafePath
            }
        } else if errno != ENOENT { return .failed(errno) }

        let opened = open(target.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard opened >= 0 else { return errno == ELOOP ? .unsafePath : .failed(errno) }
        var held = false
        defer { if !held { close(opened) } }
        var information = stat()
        guard fstat(opened, &information) == 0 else { return .failed(errno) }
        guard Self.metadataIsSafe(mode: information.st_mode, owner: information.st_uid, userID: getuid()) else {
            return .unsafePath
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            return code == EWOULDBLOCK || code == EAGAIN ? .inUse : .failed(code)
        }
        guard fchmod(opened, mode_t(0o600)) == 0 else { return .failed(errno) }

        // Refuse a path that was replaced between open and lock acquisition.
        var current = stat()
        guard lstat(target.path, &current) == 0,
              Self.metadataIsSafe(mode: current.st_mode, owner: current.st_uid, userID: getuid()),
              current.st_dev == information.st_dev, current.st_ino == information.st_ino else { return .unsafePath }

        descriptor = opened
        lockedURL = target
        held = true
        return .acquired
    }

    func release() {
        guard descriptor >= 0 else { return }
        let opened = descriptor
        descriptor = -1; lockedURL = nil
        _ = flock(opened, LOCK_UN)
        close(opened)
    }

    /// Kept pure so the foreign-owner guard is testable without elevated chown.
    static func metadataIsSafe(mode: mode_t, owner: uid_t, userID: uid_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFREG) && owner == userID
    }
}
