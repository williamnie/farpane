import Darwin
import Foundation

public enum HostAgentBootstrapProductDirectoryPreparerError: Error, Equatable {
    case insecureApplicationSupportDirectory
    case insecureProductDirectory
    case insecureHostAgentDirectory
    case creationFailed
    case syncFailed
}

public enum HostAgentBootstrapProductDirectoryPreparer {
    public static func prepare(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw HostAgentBootstrapProductLayoutError.applicationSupportUnavailable
        }
        return try prepare(applicationSupportURL: applicationSupport)
    }

    static func prepare(applicationSupportURL: URL) throws -> URL {
        guard NSString(string: applicationSupportURL.path).isAbsolutePath,
              applicationSupportURL.standardizedFileURL.path == applicationSupportURL.path
        else {
            throw HostAgentBootstrapProductDirectoryPreparerError
                .insecureApplicationSupportDirectory
        }
        let applicationSupportDescriptor = Darwin.open(
            applicationSupportURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard applicationSupportDescriptor >= 0 else {
            throw HostAgentBootstrapProductDirectoryPreparerError
                .insecureApplicationSupportDirectory
        }
        defer { Darwin.close(applicationSupportDescriptor) }
        try validateDirectory(
            applicationSupportDescriptor,
            exactPermissions: nil,
            validationError: .insecureApplicationSupportDirectory
        )

        let product = try openOrCreateDirectory(
            named: HostAgentBootstrapProductLayout.productDirectoryName,
            within: applicationSupportDescriptor,
            exactPermissions: nil,
            validationError: .insecureProductDirectory
        )
        defer { Darwin.close(product.descriptor) }
        if product.created, fsync(applicationSupportDescriptor) != 0 {
            throw HostAgentBootstrapProductDirectoryPreparerError.syncFailed
        }

        let hostAgent = try openOrCreateDirectory(
            named: HostAgentBootstrapProductLayout.hostAgentDirectoryName,
            within: product.descriptor,
            exactPermissions: 0o700,
            validationError: .insecureHostAgentDirectory
        )
        defer { Darwin.close(hostAgent.descriptor) }
        if hostAgent.created, fsync(product.descriptor) != 0 {
            throw HostAgentBootstrapProductDirectoryPreparerError.syncFailed
        }

        return HostAgentBootstrapProductLayout.directoryURL(
            applicationSupportURL: applicationSupportURL
        )
    }

    private static func openOrCreateDirectory(
        named name: String,
        within parentDescriptor: Int32,
        exactPermissions: mode_t?,
        validationError: HostAgentBootstrapProductDirectoryPreparerError
    ) throws -> (descriptor: Int32, created: Bool) {
        let created: Bool
        if mkdirat(parentDescriptor, name, mode_t(0o700)) == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw HostAgentBootstrapProductDirectoryPreparerError.creationFailed
        }

        let descriptor = Darwin.openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw validationError }
        do {
            if created, fchmod(descriptor, mode_t(0o700)) != 0 {
                throw HostAgentBootstrapProductDirectoryPreparerError.creationFailed
            }
            try validateDirectory(
                descriptor,
                exactPermissions: exactPermissions,
                validationError: validationError
            )
            return (descriptor, created)
        } catch let caughtError {
            Darwin.close(descriptor)
            throw caughtError
        }
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        exactPermissions: mode_t?,
        validationError: HostAgentBootstrapProductDirectoryPreparerError
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o022 == 0
        else { throw validationError }
        if let exactPermissions,
           status.st_mode & 0o777 != exactPermissions {
            throw validationError
        }
    }
}
