import Darwin
import Foundation

package struct ViewerFileTransferReceiveReservation: Equatable, Sendable {
    package let sessionEpoch: UInt64
    package let transferID: Int32
    package let fileNumber: Int
    package let token: UInt64
}

/// Owns a Viewer download destination directory for exactly one connection
/// epoch. The selected path is used only to open the directory; later I/O must
/// borrow the pinned descriptor through the matching opaque lease.
package final class ViewerFileTransferDestinationOwner: @unchecked Sendable {
    package static let maximumActiveReservations = 8

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct ActiveReservation {
        let handle: ViewerFileTransferReceiveReservation
        let parentDescriptor: Int32
        let fileDescriptor: Int32
        let stagingName: String
        let identity: FileIdentity
        let file: ViewerFileTransferFile
    }

    private let stateLock = NSLock()
    private let sessionEpoch: UInt64
    private let leaseToken: UInt64
    private let identity: DirectoryIdentity
    private var directoryDescriptor: Int32?
    private var activeReservations: [Int32: ActiveReservation] = [:]

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
        stateLock.lock()
        let descriptor = directoryDescriptor
        directoryDescriptor = nil
        let reservations = Array(activeReservations.values)
        activeReservations.removeAll()
        stateLock.unlock()
        reservations.forEach { _ = Self.discardReservation($0) }
        if let descriptor { Darwin.close(descriptor) }
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

    /// Reserves one descriptor-relative private staging file for a manifest
    /// entry. The returned handle contains no path or descriptor. This step
    /// does not write payload bytes or commit the final destination name.
    package func reserveNewFile(
        for request: ViewerFileTransferDownloadRequest,
        fileNumber: Int,
        reservationToken: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) -> ViewerFileTransferReceiveReservation? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard
            request.sessionEpoch == sessionEpoch,
            request.destination.sessionEpoch == sessionEpoch,
            request.destination.token == leaseToken,
            request.transferID > 0,
            fileNumber >= 0,
            fileNumber < ViewerFileTransferManifest.maximumEntries,
            request.manifest.files.indices.contains(fileNumber),
            reservationToken > 0,
            activeReservations.count < Self.maximumActiveReservations,
            activeReservations[request.transferID] == nil,
            !activeReservations.values.contains(where: { $0.handle.token == reservationToken }),
            let directoryDescriptor,
            Self.matchesPinnedDirectory(directoryDescriptor, identity: identity)
        else { return nil }
        let file = request.manifest.files[fileNumber]
        guard
            ViewerFileTransferManifest.accepts(relativePath: file.relativePath),
            let parent = Self.openOrCreatePrivateParent(
                rootDescriptor: directoryDescriptor,
                relativePath: file.relativePath
            )
        else { return nil }

        let parentDescriptor = parent.descriptor
        let finalName = parent.finalName
        var finalStatus = stat()
        let finalLookup = finalName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &finalStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard finalLookup != 0, errno == ENOENT else {
            Darwin.close(parentDescriptor)
            return nil
        }

        let stagingName = finalName + ViewerFileTransferManifest.privateStagingSuffix
        let fileDescriptor = stagingName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard fileDescriptor >= 0 else {
            Darwin.close(parentDescriptor)
            return nil
        }

        var createdStatus = stat()
        guard Darwin.fstat(fileDescriptor, &createdStatus) == 0 else {
            Darwin.close(fileDescriptor)
            Darwin.close(parentDescriptor)
            return nil
        }
        let createdIdentity = FileIdentity(
            device: createdStatus.st_dev,
            inode: createdStatus.st_ino
        )
        guard Self.isOwnedEmptyRegularFile(createdStatus) else {
            Self.discardCreatedReservation(
                parentDescriptor: parentDescriptor,
                fileDescriptor: fileDescriptor,
                stagingName: stagingName,
                identity: createdIdentity
            )
            return nil
        }

        var status = stat()
        guard
            Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0,
            Darwin.fstat(fileDescriptor, &status) == 0,
            FileIdentity(device: status.st_dev, inode: status.st_ino) == createdIdentity,
            Self.isPrivateOwnedEmptyFile(status)
        else {
            Self.discardCreatedReservation(
                parentDescriptor: parentDescriptor,
                fileDescriptor: fileDescriptor,
                stagingName: stagingName,
                identity: createdIdentity
            )
            return nil
        }

        let handle = ViewerFileTransferReceiveReservation(
            sessionEpoch: sessionEpoch,
            transferID: request.transferID,
            fileNumber: fileNumber,
            token: reservationToken
        )
        activeReservations[request.transferID] = ActiveReservation(
            handle: handle,
            parentDescriptor: parentDescriptor,
            fileDescriptor: fileDescriptor,
            stagingName: stagingName,
            identity: createdIdentity,
            file: file
        )
        return handle
    }

    /// Removes only the exact staging inode created for this reservation.
    /// A replaced or relinked entry is left untouched and reports failure.
    @discardableResult
    package func cancelReservation(
        _ handle: ViewerFileTransferReceiveReservation
    ) -> Bool {
        stateLock.lock()
        guard activeReservations[handle.transferID]?.handle == handle else {
            stateLock.unlock()
            return false
        }
        let reservation = activeReservations.removeValue(forKey: handle.transferID)!
        stateLock.unlock()
        return Self.discardReservation(reservation)
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
        let reservations = Array(activeReservations.values)
        activeReservations.removeAll()
        stateLock.unlock()
        reservations.forEach { _ = Self.discardReservation($0) }
        Darwin.close(descriptor)
        return true
    }

    private static func openOrCreatePrivateParent(
        rootDescriptor: Int32,
        relativePath: String
    ) -> (descriptor: Int32, finalName: String)? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard let final = components.last, !final.isEmpty else { return nil }
        let rootCopy = ".".withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootCopy >= 0 else { return nil }
        var rootStatus = stat()
        guard
            Darwin.fstat(rootCopy, &rootStatus) == 0,
            isPrivateOwnedDirectory(rootStatus)
        else {
            Darwin.close(rootCopy)
            return nil
        }
        var current = rootCopy

        for component in components.dropLast() {
            let name = String(component)
            var next = name.withCString {
                Darwin.openat(
                    current,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if next < 0, errno == ENOENT {
                let created = name.withCString {
                    Darwin.mkdirat(current, $0, mode_t(0o700))
                }
                if created == 0 || errno == EEXIST {
                    next = name.withCString {
                        Darwin.openat(
                            current,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                }
            }
            var status = stat()
            guard
                next >= 0,
                Darwin.fstat(next, &status) == 0,
                isPrivateOwnedDirectory(status)
            else {
                if next >= 0 { Darwin.close(next) }
                Darwin.close(current)
                return nil
            }
            Darwin.close(current)
            current = next
        }
        return (current, String(final))
    }

    private static func discardCreatedReservation(
        parentDescriptor: Int32,
        fileDescriptor: Int32,
        stagingName: String,
        identity: FileIdentity
    ) {
        var status = stat()
        let matches = stagingName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW) == 0
        } && FileIdentity(device: status.st_dev, inode: status.st_ino) == identity
        if matches {
            stagingName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
        }
        Darwin.close(fileDescriptor)
        Darwin.close(parentDescriptor)
    }

    @discardableResult
    private static func discardReservation(_ reservation: ActiveReservation) -> Bool {
        var status = stat()
        let matches = reservation.stagingName.withCString {
            Darwin.fstatat(
                reservation.parentDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        } && FileIdentity(device: status.st_dev, inode: status.st_ino) == reservation.identity
            && isPrivateOwnedEmptyFile(status)
        let removed = matches && reservation.stagingName.withCString {
            Darwin.unlinkat(reservation.parentDescriptor, $0, 0) == 0
        }
        Darwin.close(reservation.fileDescriptor)
        Darwin.close(reservation.parentDescriptor)
        return removed
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

    private static func isPrivateOwnedEmptyFile(_ status: stat) -> Bool {
        isOwnedEmptyRegularFile(status)
            && status.st_mode & mode_t(0o777) == mode_t(0o600)
    }

    private static func isOwnedEmptyRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && status.st_size == 0
    }
}
