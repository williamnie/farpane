import Darwin
import Foundation

/// Creates or reuses one fixed private child below a user-selected directory.
/// This is a product preflight only; Host Core repeats the authoritative
/// descriptor-relative ancestor/root admission when the runtime starts.
package enum HostFileTransferReceiveRootProvisioner {
    package static let receiveDirectoryName = "FarPane Receive"

    package static func provision(inside parentURL: URL) -> URL? {
        guard NSString(string: parentURL.path).isAbsolutePath,
              parentURL.standardizedFileURL.path == parentURL.path
        else { return nil }

        let parentDescriptor = parentURL.withUnsafeFileSystemRepresentation {
            path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard parentDescriptor >= 0 else { return nil }
        defer { Darwin.close(parentDescriptor) }

        var parentStatus = stat()
        guard Darwin.fstat(parentDescriptor, &parentStatus) == 0,
              isOwnedDirectory(parentStatus),
              parentStatus.st_mode & mode_t(0o022) == 0
        else { return nil }

        let created = receiveDirectoryName.withCString { name in
            Darwin.mkdirat(parentDescriptor, name, mode_t(0o700)) == 0
        }
        if !created, errno != EEXIST { return nil }

        let childDescriptor = receiveDirectoryName.withCString { name in
            Darwin.openat(
                parentDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard childDescriptor >= 0 else { return nil }
        defer { Darwin.close(childDescriptor) }

        if created, Darwin.fchmod(childDescriptor, mode_t(0o700)) != 0 {
            return nil
        }
        var childStatus = stat()
        guard Darwin.fstat(childDescriptor, &childStatus) == 0,
              isOwnedDirectory(childStatus),
              childStatus.st_mode & mode_t(0o777) == mode_t(0o700)
        else { return nil }

        let childURL = parentURL.appendingPathComponent(
            receiveDirectoryName,
            isDirectory: true
        )
        guard childURL.standardizedFileURL.path == childURL.path else {
            return nil
        }
        return childURL
    }

    private static func isOwnedDirectory(_ status: stat) -> Bool {
        status.st_uid == geteuid()
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }
}
