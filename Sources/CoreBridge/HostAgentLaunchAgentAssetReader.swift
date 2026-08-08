import Darwin
import Foundation

package enum HostAgentLaunchAgentAssetReaderError: Error, Equatable {
    case unavailable
    case unsafeLayout
    case invalidSize
    case readFailed
}

/// Reads the LaunchAgent declaration only from the fixed app-bundle resource.
/// Descriptor-relative traversal prevents path replacement or symlink fallback
/// while the bytes are being selected and read.
package enum HostAgentLaunchAgentAssetReader {
    private static let directoryComponents = [
        "Contents",
        "Library",
        "LaunchAgents",
    ]
    private static let fileName =
        "io.rustdesknative.viewer.host-agent.plist"

    /// Product entry point: callers cannot inject plist bytes or a path.
    package static func readMainBundle() throws -> Data {
        try readBundle(at: Bundle.main.bundleURL)
    }

    static func readBundle(at bundleURL: URL) throws -> Data {
        var directoryDescriptors: [Int32] = []
        defer {
            for descriptor in directoryDescriptors.reversed() {
                Darwin.close(descriptor)
            }
        }

        let bundleDescriptor = try openRootDirectory(at: bundleURL)
        directoryDescriptors.append(bundleDescriptor)

        var parentDescriptor = bundleDescriptor
        for component in directoryComponents {
            let descriptor = try openDirectory(
                named: component,
                relativeTo: parentDescriptor
            )
            directoryDescriptors.append(descriptor)
            parentDescriptor = descriptor
        }

        let fileDescriptor = try openAsset(relativeTo: parentDescriptor)
        defer { Darwin.close(fileDescriptor) }

        var initialStatus = stat()
        guard Darwin.fstat(fileDescriptor, &initialStatus) == 0 else {
            throw HostAgentLaunchAgentAssetReaderError.readFailed
        }
        guard isTrustedFile(initialStatus) else {
            throw HostAgentLaunchAgentAssetReaderError.unsafeLayout
        }
        guard initialStatus.st_size > 0,
              initialStatus.st_size
                <= off_t(HostAgentLaunchAgentPlistPreflight.maximumPayloadBytes)
        else {
            throw HostAgentLaunchAgentAssetReaderError.invalidSize
        }

        let expectedSize = Int(initialStatus.st_size)
        var data = Data(count: expectedSize)
        var offset = 0
        while offset < expectedSize {
            let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.read(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    expectedSize - offset
                )
            }
            if bytesRead < 0, errno == EINTR {
                continue
            }
            guard bytesRead > 0 else {
                throw HostAgentLaunchAgentAssetReaderError.readFailed
            }
            offset += bytesRead
        }

        var trailingByte: UInt8 = 0
        while true {
            let trailingCount = Darwin.read(fileDescriptor, &trailingByte, 1)
            if trailingCount < 0, errno == EINTR {
                continue
            }
            guard trailingCount == 0 else {
                throw HostAgentLaunchAgentAssetReaderError.readFailed
            }
            break
        }

        var finalStatus = stat()
        guard Darwin.fstat(fileDescriptor, &finalStatus) == 0,
              sameFileSnapshot(initialStatus, finalStatus)
        else {
            throw HostAgentLaunchAgentAssetReaderError.readFailed
        }
        return data
    }

    private static func openRootDirectory(at url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            )
        }
        guard descriptor >= 0 else {
            throw openFailure(for: errno)
        }
        guard trustedDirectory(descriptor) else {
            Darwin.close(descriptor)
            throw HostAgentLaunchAgentAssetReaderError.unsafeLayout
        }
        return descriptor
    }

    private static func openDirectory(
        named name: String,
        relativeTo parentDescriptor: Int32
    ) throws -> Int32 {
        let descriptor = name.withCString { namePointer in
            Darwin.openat(
                parentDescriptor,
                namePointer,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
            )
        }
        guard descriptor >= 0 else {
            throw openFailure(for: errno)
        }
        guard trustedDirectory(descriptor) else {
            Darwin.close(descriptor)
            throw HostAgentLaunchAgentAssetReaderError.unsafeLayout
        }
        return descriptor
    }

    private static func openAsset(relativeTo parentDescriptor: Int32) throws
        -> Int32
    {
        let descriptor = fileName.withCString { namePointer in
            Darwin.openat(
                parentDescriptor,
                namePointer,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw openFailure(for: errno)
        }
        return descriptor
    }

    private static func trustedDirectory(_ descriptor: Int32) -> Bool {
        var status = stat()
        return Darwin.fstat(descriptor, &status) == 0
            && status.st_mode & S_IFMT == S_IFDIR
            && trustedOwner(status.st_uid)
            && status.st_mode & mode_t(0o022) == 0
    }

    private static func isTrustedFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && trustedOwner(status.st_uid)
            && status.st_mode & mode_t(0o022) == 0
            && status.st_nlink == 1
    }

    private static func trustedOwner(_ owner: uid_t) -> Bool {
        owner == 0 || owner == geteuid()
    }

    private static func openFailure(for errorNumber: Int32)
        -> HostAgentLaunchAgentAssetReaderError
    {
        errorNumber == ENOENT ? .unavailable : .unsafeLayout
    }

    private static func sameFileSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
