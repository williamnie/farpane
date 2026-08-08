import Foundation

public enum HostAgentBootstrapProductLayoutError: Error, Equatable {
    case applicationSupportUnavailable
}

public enum HostAgentBootstrapProductLayout {
    public static let productDirectoryName = "RustDesk Native Viewer"
    public static let hostAgentDirectoryName = "HostAgent"

    public static func directoryURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw HostAgentBootstrapProductLayoutError.applicationSupportUnavailable
        }
        return directoryURL(applicationSupportURL: applicationSupport)
    }

    static func directoryURL(applicationSupportURL: URL) -> URL {
        applicationSupportURL
            .appendingPathComponent(productDirectoryName, isDirectory: true)
            .appendingPathComponent(hostAgentDirectoryName, isDirectory: true)
    }
}
