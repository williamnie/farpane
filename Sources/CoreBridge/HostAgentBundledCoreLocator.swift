import Darwin
import Foundation

public enum HostAgentBundledCoreLocatorError: Error, Equatable {
    case privateFrameworksUnavailable
    case unsafeFrameworksDirectory
    case coreUnavailable
    case unsafeCoreFile
}

/// Resolves the HostAgent Core only from the product bundle. The
/// concrete Core client remains responsible for ABI and pinned-upstream checks.
public enum HostAgentBundledCoreLocator {
    public static let coreLibraryFileName = "liblibrustdesk.dylib"

    /// Product entry point: callers cannot inject a path, environment value or
    /// current-working-directory fallback.
    public static func locate() throws -> URL {
        guard let privateFrameworksURL = Bundle.main.privateFrameworksURL else {
            throw HostAgentBundledCoreLocatorError.privateFrameworksUnavailable
        }
        return try locate(privateFrameworksURL: privateFrameworksURL)
    }

    static func locate(privateFrameworksURL: URL) throws -> URL {
        let frameworksResult = fileStatus(at: privateFrameworksURL)
        guard let frameworksStatus = frameworksResult.status,
              frameworksStatus.st_mode & S_IFMT == S_IFDIR,
              trustedOwner(frameworksStatus.st_uid),
              frameworksStatus.st_mode & mode_t(0o022) == 0
        else {
            throw HostAgentBundledCoreLocatorError.unsafeFrameworksDirectory
        }

        let coreURL = privateFrameworksURL.appendingPathComponent(
            coreLibraryFileName,
            isDirectory: false
        )
        guard coreURL.standardizedFileURL.deletingLastPathComponent()
                == privateFrameworksURL.standardizedFileURL
        else {
            throw HostAgentBundledCoreLocatorError.unsafeCoreFile
        }

        let coreResult = fileStatus(at: coreURL)
        guard let coreStatus = coreResult.status else {
            if coreResult.error == ENOENT {
                throw HostAgentBundledCoreLocatorError.coreUnavailable
            }
            throw HostAgentBundledCoreLocatorError.unsafeCoreFile
        }
        guard coreStatus.st_mode & S_IFMT == S_IFREG,
              coreStatus.st_uid == frameworksStatus.st_uid,
              coreStatus.st_mode & mode_t(0o022) == 0,
              coreStatus.st_nlink == 1,
              coreStatus.st_size > 0
        else {
            throw HostAgentBundledCoreLocatorError.unsafeCoreFile
        }
        return coreURL
    }

    private static func trustedOwner(_ owner: uid_t) -> Bool {
        owner == 0 || owner == geteuid()
    }

    private static func fileStatus(
        at url: URL
    ) -> (status: stat?, error: Int32) {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        let capturedError = result == 0 ? 0 : errno
        return (result == 0 ? status : nil, capturedError)
    }
}
