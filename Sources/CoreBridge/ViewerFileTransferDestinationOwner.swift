import Darwin
import Foundation

/// Owns a Viewer download destination directory for exactly one connection
/// epoch. The selected path is used only to open the directory; later I/O must
/// borrow the pinned descriptor through the matching opaque lease.
package final class ViewerFileTransferDestinationOwner: @unchecked Sendable {
    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private let stateLock = NSLock()
    private let sessionEpoch: UInt64
    private let leaseToken: UInt64
    private let identity: DirectoryIdentity
    private var directoryDescriptor: Int32?

    package init?(
        sessionEpoch: UInt64,
        directoryURL: URL,
        leaseToken: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) {
        guard
            sessionEpoch > 0,
            leaseToken > 0,
            NSString(string: directoryURL.path).isAbsolutePath,
            directoryURL.standardizedFileURL.path == directoryURL.path
        else { return nil }

        let descriptor = directoryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return nil }

        var status = stat()
        guard
            Darwin.fstat(descriptor, &status) == 0,
            Self.isPrivateOwnedDirectory(status)
        else {
            Darwin.close(descriptor)
            return nil
        }

        self.sessionEpoch = sessionEpoch
        self.leaseToken = leaseToken
        identity = DirectoryIdentity(device: status.st_dev, inode: status.st_ino)
        directoryDescriptor = descriptor
    }

    deinit {
        if let directoryDescriptor {
            Darwin.close(directoryDescriptor)
        }
    }

    package var lease: ViewerFileTransferDestinationLease? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard directoryDescriptor != nil else { return nil }
        return ViewerFileTransferDestinationLease(
            token: leaseToken,
            sessionEpoch: sessionEpoch
        )
    }

    /// The descriptor is valid only for the duration of `body`. Holding the
    /// lock across the callback prevents teardown from closing a borrowed fd.
    package func withPinnedDirectoryDescriptor<Result>(
        for lease: ViewerFileTransferDestinationLease,
        _ body: (Int32) throws -> Result
    ) rethrows -> Result? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard
            lease.sessionEpoch == sessionEpoch,
            lease.token == leaseToken,
            let directoryDescriptor,
            Self.matchesPinnedDirectory(
                directoryDescriptor,
                identity: identity
            )
        else { return nil }
        return try body(directoryDescriptor)
    }

    /// Closes the pinned descriptor only for the exact owning connection epoch.
    @discardableResult
    package func teardown(sessionEpoch: UInt64) -> Bool {
        stateLock.lock()
        guard
            sessionEpoch > 0,
            sessionEpoch == self.sessionEpoch,
            let descriptor = directoryDescriptor
        else {
            stateLock.unlock()
            return false
        }
        directoryDescriptor = nil
        stateLock.unlock()
        Darwin.close(descriptor)
        return true
    }

    private static func matchesPinnedDirectory(
        _ descriptor: Int32,
        identity: DirectoryIdentity
    ) -> Bool {
        var status = stat()
        return Darwin.fstat(descriptor, &status) == 0
            && DirectoryIdentity(device: status.st_dev, inode: status.st_ino) == identity
            && isPrivateOwnedDirectory(status)
    }

    private static func isPrivateOwnedDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == geteuid()
            && status.st_mode & mode_t(0o777) == mode_t(0o700)
            && status.st_nlink > 0
    }
}
