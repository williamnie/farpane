import Darwin
import Foundation

public enum HostAgentBootstrapConfigurationPublicationResult: Equatable, Sendable {
    case published
    case unchanged
}

public enum HostAgentBootstrapConfigurationPublisherError: Error, Equatable {
    case directoryUnavailable
    case insecureDirectory
    case insecurePublicationLock
    case publicationBusy
    case nonMonotonicRevision(current: UInt64, proposed: UInt64)
    case writeFailed
    case directorySyncFailed
}

/// Publishes a validated, non-secret projection of the product server config.
/// This never writes RustDesk identity/config files or accepts a wire path.
public final class HostAgentBootstrapConfigurationPublisher: @unchecked Sendable {
    static let publicationLockFileName = ".bootstrap-publication.lock"
    private static let temporaryFilePrefix = ".bootstrap-v1.json.tmp."

    private let directoryURL: URL

    public convenience init(fileManager: FileManager = .default) throws {
        try self.init(
            directoryURL: HostAgentBootstrapProductLayout.directoryURL(
                fileManager: fileManager
            )
        )
    }

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func publish(
        _ document: Data
    ) throws -> HostAgentBootstrapConfigurationPublicationResult {
        let proposed = try HostAgentBootstrapConfiguration.decode(document)
        let directoryDescriptor = try openSecureDirectory()
        defer { Darwin.close(directoryDescriptor) }

        let lockDescriptor = try acquirePublicationLock(in: directoryDescriptor)
        defer {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }

        do {
            let existingData = try HostAgentBootstrapConfigurationReader.readDocument(
                fromDirectoryDescriptor: directoryDescriptor
            )
            let existing = try HostAgentBootstrapConfiguration.decode(existingData)
            if existing.configRevision == proposed.configRevision,
               existingData == document {
                return .unchanged
            }
            guard proposed.configRevision > existing.configRevision else {
                throw HostAgentBootstrapConfigurationPublisherError.nonMonotonicRevision(
                    current: existing.configRevision,
                    proposed: proposed.configRevision
                )
            }
        } catch HostAgentBootstrapConfigurationReaderError.configurationUnavailable {
            // First publication has no prior revision.
        }

        try replaceAtomically(document, in: directoryDescriptor)
        return .published
    }

    private func openSecureDirectory() throws -> Int32 {
        guard NSString(string: directoryURL.path).isAbsolutePath,
              directoryURL.standardizedFileURL.path == directoryURL.path
        else { throw HostAgentBootstrapConfigurationPublisherError.insecureDirectory }
        let descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw HostAgentBootstrapConfigurationPublisherError.insecureDirectory
            }
            throw HostAgentBootstrapConfigurationPublisherError.directoryUnavailable
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            Darwin.close(descriptor)
            throw HostAgentBootstrapConfigurationPublisherError.directoryUnavailable
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o700
        else {
            Darwin.close(descriptor)
            throw HostAgentBootstrapConfigurationPublisherError.insecureDirectory
        }
        return descriptor
    }

    private func acquirePublicationLock(in directoryDescriptor: Int32) throws -> Int32 {
        let createFlags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        var descriptor = Darwin.openat(
            directoryDescriptor,
            Self.publicationLockFileName,
            createFlags,
            mode_t(0o600)
        )
        let created = descriptor >= 0
        if !created, errno == EEXIST {
            descriptor = Darwin.openat(
                directoryDescriptor,
                Self.publicationLockFileName,
                O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw HostAgentBootstrapConfigurationPublisherError.insecurePublicationLock
        }

        if created, fchmod(descriptor, mode_t(0o600)) != 0 {
            Darwin.close(descriptor)
            unlinkat(directoryDescriptor, Self.publicationLockFileName, 0)
            throw HostAgentBootstrapConfigurationPublisherError.insecurePublicationLock
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o600,
              status.st_nlink == 1
        else {
            Darwin.close(descriptor)
            throw HostAgentBootstrapConfigurationPublisherError.insecurePublicationLock
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw HostAgentBootstrapConfigurationPublisherError.publicationBusy
        }
        return descriptor
    }

    private func replaceAtomically(_ document: Data, in directoryDescriptor: Int32) throws {
        let temporaryName = Self.temporaryFilePrefix + UUID().uuidString
        let temporaryDescriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryDescriptor >= 0 else {
            throw HostAgentBootstrapConfigurationPublisherError.writeFailed
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryDescriptor)
            if shouldRemoveTemporary {
                unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        guard fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
            throw HostAgentBootstrapConfigurationPublisherError.writeFailed
        }
        try writeAll(document, to: temporaryDescriptor)
        guard fsync(temporaryDescriptor) == 0 else {
            throw HostAgentBootstrapConfigurationPublisherError.writeFailed
        }
        guard renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            HostAgentBootstrapConfigurationReader.configurationFileName
        ) == 0 else {
            throw HostAgentBootstrapConfigurationPublisherError.writeFailed
        }
        shouldRemoveTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            throw HostAgentBootstrapConfigurationPublisherError.directorySyncFailed
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw HostAgentBootstrapConfigurationPublisherError.writeFailed
            }
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw HostAgentBootstrapConfigurationPublisherError.writeFailed
            }
        }
    }
}
