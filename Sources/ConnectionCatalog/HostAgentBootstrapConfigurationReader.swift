import Darwin
import Foundation

public enum HostAgentBootstrapConfigurationReaderError: Error, Equatable {
    case directoryUnavailable
    case insecureDirectory
    case configurationUnavailable
    case insecureConfigurationFile
    case readFailed
}

/// Reads the fixed HostAgent bootstrap document from a directory chosen by a
/// higher-level product authority. The directory URL is never accepted from
/// wire input. Publication and the final product directory are later gates.
public final class HostAgentBootstrapConfigurationReader: @unchecked Sendable {
    public static let configurationFileName = "bootstrap-v1.json"

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

    public func load() throws -> HostAgentBootstrapConfiguration {
        try HostAgentBootstrapConfiguration.decode(readDocument())
    }

    func readDocument() throws -> Data {
        guard NSString(string: directoryURL.path).isAbsolutePath,
              directoryURL.standardizedFileURL.path == directoryURL.path
        else { throw HostAgentBootstrapConfigurationReaderError.insecureDirectory }

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
        else { throw HostAgentBootstrapConfigurationReaderError.insecureDirectory }

        return try Self.readDocument(fromDirectoryDescriptor: directoryDescriptor)
    }

    static func readDocument(fromDirectoryDescriptor directoryDescriptor: Int32) throws -> Data {
        let configurationDescriptor = Darwin.openat(
            directoryDescriptor,
            Self.configurationFileName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard configurationDescriptor >= 0 else {
            switch errno {
            case ENOENT:
                throw HostAgentBootstrapConfigurationReaderError.configurationUnavailable
            case ELOOP:
                throw HostAgentBootstrapConfigurationReaderError.insecureConfigurationFile
            default:
                throw HostAgentBootstrapConfigurationReaderError.readFailed
            }
        }
        defer { Darwin.close(configurationDescriptor) }

        var configurationStatus = stat()
        guard fstat(configurationDescriptor, &configurationStatus) == 0 else {
            throw HostAgentBootstrapConfigurationReaderError.readFailed
        }
        guard configurationStatus.st_mode & S_IFMT == S_IFREG,
              configurationStatus.st_uid == geteuid(),
              configurationStatus.st_mode & 0o777 == 0o600,
              configurationStatus.st_nlink == 1
        else {
            throw HostAgentBootstrapConfigurationReaderError.insecureConfigurationFile
        }
        guard configurationStatus.st_size
            <= HostAgentBootstrapConfiguration.maximumDocumentBytes
        else { throw HostAgentBootstrapConfigurationError.documentTooLarge }

        return try readBounded(from: configurationDescriptor)
    }

    private static func readBounded(from descriptor: Int32) throws -> Data {
        let maximumBytes = HostAgentBootstrapConfiguration.maximumDocumentBytes
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)

        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > maximumBytes {
                    throw HostAgentBootstrapConfigurationError.documentTooLarge
                }
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            throw HostAgentBootstrapConfigurationReaderError.readFailed
        }
        throw HostAgentBootstrapConfigurationError.documentTooLarge
    }
}
