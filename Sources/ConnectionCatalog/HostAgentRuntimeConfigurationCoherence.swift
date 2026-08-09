import Darwin
import Foundation

public enum HostAgentRuntimeConfigurationObservationError: Error, Equatable {
    case leaseUnavailable
    case insecureLeaseFile
    case leaseReadFailed
}

public struct HostAgentRuntimeConfigurationObservation: Equatable, Sendable {
    public let bootstrap: HostAgentBootstrapConfiguration
    public let lease: HostAgentSingleWriterLeaseRecord

    init(
        bootstrap: HostAgentBootstrapConfiguration,
        lease: HostAgentSingleWriterLeaseRecord
    ) {
        self.bootstrap = bootstrap
        self.lease = lease
    }
}

/// Reads the two fixed, non-secret HostAgent runtime identity documents.
/// A higher layer must still correlate this evidence with an authenticated
/// live XPC peer; file presence by itself never proves process liveness.
public final class HostAgentRuntimeConfigurationObservationReader:
    @unchecked Sendable
{
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

    public func load() throws -> HostAgentRuntimeConfigurationObservation {
        guard NSString(string: directoryURL.path).isAbsolutePath,
              directoryURL.standardizedFileURL.path == directoryURL.path
        else {
            throw HostAgentBootstrapConfigurationReaderError.insecureDirectory
        }

        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw HostAgentBootstrapConfigurationReaderError.insecureDirectory
            }
            throw HostAgentBootstrapConfigurationReaderError.directoryUnavailable
        }
        defer { Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0 else {
            throw HostAgentBootstrapConfigurationReaderError.directoryUnavailable
        }
        guard directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & 0o777 == 0o700
        else {
            throw HostAgentBootstrapConfigurationReaderError.insecureDirectory
        }

        let bootstrap = try HostAgentBootstrapConfiguration.decode(
            HostAgentBootstrapConfigurationReader.readDocument(
                fromDirectoryDescriptor: directoryDescriptor
            )
        )
        let lease = try readLeaseRecord(
            fromDirectoryDescriptor: directoryDescriptor
        )
        return HostAgentRuntimeConfigurationObservation(
            bootstrap: bootstrap,
            lease: lease
        )
    }

    private func readLeaseRecord(
        fromDirectoryDescriptor directoryDescriptor: Int32
    ) throws -> HostAgentSingleWriterLeaseRecord {
        let descriptor = Darwin.openat(
            directoryDescriptor,
            HostAgentSingleWriterLease.leaseFileName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw HostAgentRuntimeConfigurationObservationError
                    .leaseUnavailable
            }
            if errno == ELOOP {
                throw HostAgentRuntimeConfigurationObservationError
                    .insecureLeaseFile
            }
            throw HostAgentRuntimeConfigurationObservationError
                .leaseReadFailed
        }
        defer { Darwin.close(descriptor) }

        var leaseStatus = stat()
        guard fstat(descriptor, &leaseStatus) == 0 else {
            throw HostAgentRuntimeConfigurationObservationError.leaseReadFailed
        }
        guard leaseStatus.st_mode & S_IFMT == S_IFREG,
              leaseStatus.st_uid == geteuid(),
              leaseStatus.st_mode & 0o777 == 0o600,
              leaseStatus.st_nlink == 1
        else {
            throw HostAgentRuntimeConfigurationObservationError
                .insecureLeaseFile
        }
        guard leaseStatus.st_size >= 0,
              leaseStatus.st_size
                <= HostAgentSingleWriterLeaseRecord.maximumDocumentBytes
        else {
            throw HostAgentSingleWriterLeaseRecordError.documentTooLarge
        }

        return try HostAgentSingleWriterLeaseRecord.decode(
            readBounded(from: descriptor)
        )
    }

    private func readBounded(from descriptor: Int32) throws -> Data {
        let maximumBytes = HostAgentSingleWriterLeaseRecord.maximumDocumentBytes
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)

        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > maximumBytes {
                    throw HostAgentSingleWriterLeaseRecordError.documentTooLarge
                }
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw HostAgentRuntimeConfigurationObservationError.leaseReadFailed
        }
        throw HostAgentSingleWriterLeaseRecordError.documentTooLarge
    }
}

public enum HostAgentRuntimeConfigurationCoherence: Equatable, Sendable {
    case waitingForLivePeer
    case evidenceUnavailable
    case coherent(configRevision: UInt64)
    case staleConfiguration(
        expectedRevision: UInt64,
        runningRevision: UInt64
    )
    case identityMismatch

    public var permitsRuntimeProjection: Bool {
        if case .coherent = self { return true }
        return false
    }
}

public enum HostAgentRuntimeConfigurationCoherencePolicy {
    public static func evaluate(
        observation: HostAgentRuntimeConfigurationObservation,
        liveAgentBuildID: String,
        liveAgentBootID: String
    ) -> HostAgentRuntimeConfigurationCoherence {
        let bootstrap = observation.bootstrap
        let lease = observation.lease

        guard bootstrap.configRevision == lease.configRevision else {
            return .staleConfiguration(
                expectedRevision: bootstrap.configRevision,
                runningRevision: lease.configRevision
            )
        }
        guard bootstrap.agentBuildID == lease.agentBuildID,
              lease.agentBuildID == liveAgentBuildID,
              let liveBootID = UUID(uuidString: liveAgentBootID),
              liveBootID.uuidString.lowercased() == liveAgentBootID,
              liveBootID == lease.agentBootID
        else {
            return .identityMismatch
        }
        return .coherent(configRevision: bootstrap.configRevision)
    }
}
