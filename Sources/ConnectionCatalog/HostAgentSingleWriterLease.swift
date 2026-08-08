import Darwin
import Foundation

public enum HostAgentSingleWriterLeaseRecordError: Error, Equatable {
    case documentTooLarge
    case unsupportedSchema(Int)
    case invalidDocument
}

public struct HostAgentSingleWriterLeaseRecord: Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumDocumentBytes = 1_024

    public let schemaVersion: Int
    public let agentBootID: UUID
    public let agentBuildID: String
    public let configRevision: UInt64

    init(
        agentBootID: UUID,
        agentBuildID: String,
        configRevision: UInt64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.agentBootID = agentBootID
        self.agentBuildID = agentBuildID
        self.configRevision = configRevision
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else {
            throw HostAgentSingleWriterLeaseRecordError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentSingleWriterLeaseRecordError.documentTooLarge
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HostAgentSingleWriterLeaseRecordError.invalidDocument
        }
        guard let document = value as? [String: Any],
              Set(document.keys) == Set([
                  "schemaVersion", "agentBootID", "agentBuildID", "configRevision",
              ]),
              let schemaValue = HostAgentBootstrapConfiguration.strictUInt64(
                  document["schemaVersion"]
              ),
              schemaValue <= UInt64(Int.max)
        else {
            throw HostAgentSingleWriterLeaseRecordError.invalidDocument
        }
        let schemaVersion = Int(schemaValue)
        guard schemaVersion == currentSchemaVersion else {
            throw HostAgentSingleWriterLeaseRecordError.unsupportedSchema(schemaVersion)
        }
        guard let bootIDValue = document["agentBootID"] as? String,
              let agentBootID = UUID(uuidString: bootIDValue),
              agentBootID.uuidString == bootIDValue,
              let agentBuildID = document["agentBuildID"] as? String,
              HostAgentBootstrapConfiguration.validAgentBuildID(agentBuildID),
              let configRevision = HostAgentBootstrapConfiguration.strictUInt64(
                  document["configRevision"]
              ),
              (1...HostAgentBootstrapConfiguration.maximumConfigRevision).contains(
                  configRevision
              )
        else {
            throw HostAgentSingleWriterLeaseRecordError.invalidDocument
        }
        return Self(
            agentBootID: agentBootID,
            agentBuildID: agentBuildID,
            configRevision: configRevision
        )
    }

    func encode() throws -> Data {
        let value: [String: Any] = [
            "schemaVersion": Self.currentSchemaVersion,
            "agentBootID": agentBootID.uuidString,
            "agentBuildID": agentBuildID,
            "configRevision": NSNumber(value: configRevision),
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            guard try Self.decode(data) == self else {
                throw HostAgentSingleWriterLeaseRecordError.invalidDocument
            }
        } catch let error as HostAgentSingleWriterLeaseRecordError {
            throw error
        } catch {
            throw HostAgentSingleWriterLeaseRecordError.invalidDocument
        }
        return data
    }
}

public enum HostAgentSingleWriterLeaseError: Error, Equatable {
    case directoryUnavailable
    case insecureDirectory
    case insecureLeaseFile
    case alreadyHeld
    case leaseUnavailable
    case recordWriteFailed
}

/// Process-lifetime exclusive ownership for the Host Rust config namespace.
/// The fixed file remains after release; the live `flock`, not file presence,
/// is the ownership authority.
public final class HostAgentSingleWriterLease: @unchecked Sendable {
    static let leaseFileName = ".host-agent-runtime-v1.lock"

    public let record: HostAgentSingleWriterLeaseRecord

    private let stateLock = NSLock()
    private var descriptor: Int32?

    private init(descriptor: Int32, record: HostAgentSingleWriterLeaseRecord) {
        self.descriptor = descriptor
        self.record = record
    }

    deinit {
        release()
    }

    public static func acquire(
        configuration: HostAgentBootstrapConfiguration,
        agentBootID: UUID
    ) throws -> HostAgentSingleWriterLease {
        try acquire(
            directoryURL: HostAgentBootstrapProductLayout.directoryURL(),
            configuration: configuration,
            agentBootID: agentBootID
        )
    }

    static func acquire(
        directoryURL: URL,
        configuration: HostAgentBootstrapConfiguration,
        agentBootID: UUID
    ) throws -> HostAgentSingleWriterLease {
        let record = HostAgentSingleWriterLeaseRecord(
            agentBootID: agentBootID,
            agentBuildID: configuration.agentBuildID,
            configRevision: configuration.configRevision
        )
        let recordData = try record.encode()
        let directoryDescriptor = try openSecureDirectory(directoryURL)
        defer { Darwin.close(directoryDescriptor) }

        let leaseDescriptor = try openAndLockLease(
            directoryDescriptor: directoryDescriptor
        )
        do {
            try writeAndVerify(
                recordData,
                record: record,
                descriptor: leaseDescriptor
            )
            guard fsync(directoryDescriptor) == 0 else {
                throw HostAgentSingleWriterLeaseError.recordWriteFailed
            }
            return HostAgentSingleWriterLease(
                descriptor: leaseDescriptor,
                record: record
            )
        } catch {
            flock(leaseDescriptor, LOCK_UN)
            Darwin.close(leaseDescriptor)
            throw error
        }
    }

    public func release() {
        stateLock.lock()
        let descriptor = self.descriptor
        self.descriptor = nil
        stateLock.unlock()
        guard let descriptor else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private static func openSecureDirectory(_ directoryURL: URL) throws -> Int32 {
        guard NSString(string: directoryURL.path).isAbsolutePath,
              directoryURL.standardizedFileURL.path == directoryURL.path
        else {
            throw HostAgentSingleWriterLeaseError.insecureDirectory
        }
        let descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw HostAgentSingleWriterLeaseError.insecureDirectory
            }
            throw HostAgentSingleWriterLeaseError.directoryUnavailable
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o700
        else {
            Darwin.close(descriptor)
            throw HostAgentSingleWriterLeaseError.insecureDirectory
        }
        return descriptor
    }

    private static func openAndLockLease(
        directoryDescriptor: Int32
    ) throws -> Int32 {
        var descriptor = Darwin.openat(
            directoryDescriptor,
            leaseFileName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            mode_t(0o600)
        )
        let created = descriptor >= 0
        if !created, errno == EEXIST {
            descriptor = Darwin.openat(
                directoryDescriptor,
                leaseFileName,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            throw HostAgentSingleWriterLeaseError.insecureLeaseFile
        }
        if created, fchmod(descriptor, mode_t(0o600)) != 0 {
            Darwin.close(descriptor)
            throw HostAgentSingleWriterLeaseError.insecureLeaseFile
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o600,
              status.st_nlink == 1
        else {
            Darwin.close(descriptor)
            throw HostAgentSingleWriterLeaseError.insecureLeaseFile
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK {
                throw HostAgentSingleWriterLeaseError.alreadyHeld
            }
            throw HostAgentSingleWriterLeaseError.leaseUnavailable
        }
        return descriptor
    }

    private static func writeAndVerify(
        _ data: Data,
        record: HostAgentSingleWriterLeaseRecord,
        descriptor: Int32
    ) throws {
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) >= 0
        else {
            throw HostAgentSingleWriterLeaseError.recordWriteFailed
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw HostAgentSingleWriterLeaseError.recordWriteFailed
            }
        }
        guard fsync(descriptor) == 0,
              lseek(descriptor, 0, SEEK_SET) >= 0
        else {
            throw HostAgentSingleWriterLeaseError.recordWriteFailed
        }
        var verified = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                verified.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw HostAgentSingleWriterLeaseError.recordWriteFailed
            }
            guard verified.count <= HostAgentSingleWriterLeaseRecord.maximumDocumentBytes else {
                throw HostAgentSingleWriterLeaseError.recordWriteFailed
            }
        }
        guard verified == data,
              try HostAgentSingleWriterLeaseRecord.decode(verified) == record
        else {
            throw HostAgentSingleWriterLeaseError.recordWriteFailed
        }
    }
}
