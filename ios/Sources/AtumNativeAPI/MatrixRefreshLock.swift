import Foundation
import Darwin

public enum MatrixRefreshFailure: Error, Equatable {
    case busy, unavailable, recordChanged, timedOut, keychainLocked
}

/// Separate from the SDK database lease: protects the Keychain read/journal/
/// HTTP spend/commit transaction before an SDK client exists. Never unlink this
/// file: replacing its inode would let another process acquire a different lock.
public final class MatrixRefreshLease {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }

    static func acquire(at lockURL: URL? = nil) throws -> MatrixRefreshLease {
        let url: URL
        if let lockURL { url = lockURL }
        else {
            #if os(iOS)
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.atum.mobile.shared") else {
                throw MatrixRefreshFailure.unavailable
            }
            url = group.appendingPathComponent("matrix-refresh.lock")
            #else
            throw MatrixRefreshFailure.unavailable
            #endif
        }
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MatrixRefreshFailure.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? MatrixRefreshFailure.busy : .unavailable
        }
        #if os(iOS)
        do {
            // The empty lock file carries no secrets. Like the store, it must
            // remain usable on a locked phone after first unlock.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        } catch {
            flock(fd, LOCK_UN); close(fd)
            throw MatrixRefreshFailure.unavailable
        }
        #endif
        return MatrixRefreshLease(descriptor: fd)
    }
}
