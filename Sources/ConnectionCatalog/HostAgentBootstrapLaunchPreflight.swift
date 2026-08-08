import Foundation

public enum HostAgentBootstrapLaunchPreflightError: Error, Equatable {
    case buildIdentifierUnavailable
    case buildIdentifierMismatch
}

/// Read-only HostAgent launch gate. The product entry point accepts neither a
/// disk path nor a build identifier: both authorities come from the installed
/// App bundle and the fixed user Application Support layout.
public final class HostAgentBootstrapLaunchPreflight: @unchecked Sendable {
    private let applicationSupportURL: URL

    public init() throws {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw HostAgentBootstrapProductLayoutError.applicationSupportUnavailable
        }
        self.applicationSupportURL = applicationSupportURL
    }

    init(applicationSupportURL: URL) {
        self.applicationSupportURL = applicationSupportURL
    }

    public func prepare() throws -> HostAgentBootstrapConfiguration {
        guard let expectedAgentBuildID = HostAgentBootstrapBuildIdentifier.resolve(
            from: Bundle.main.infoDictionary
        ) else {
            throw HostAgentBootstrapLaunchPreflightError.buildIdentifierUnavailable
        }
        return try prepare(expectedAgentBuildID: expectedAgentBuildID)
    }

    package func prepare(
        expectedAgentBuildID: String
    ) throws -> HostAgentBootstrapConfiguration {
        guard HostAgentBootstrapConfiguration.validAgentBuildID(expectedAgentBuildID) else {
            throw HostAgentBootstrapLaunchPreflightError.buildIdentifierUnavailable
        }
        let configuration = try HostAgentBootstrapConfigurationReader(
            directoryURL: HostAgentBootstrapProductLayout.directoryURL(
                applicationSupportURL: applicationSupportURL
            )
        ).load()
        guard configuration.agentBuildID == expectedAgentBuildID else {
            throw HostAgentBootstrapLaunchPreflightError.buildIdentifierMismatch
        }
        return configuration
    }
}
