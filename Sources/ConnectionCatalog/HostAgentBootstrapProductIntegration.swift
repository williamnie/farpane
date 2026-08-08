import Foundation

public enum HostAgentBootstrapProductIntegrationError: Error, Equatable {
    case buildIdentifierUnavailable
}

public enum HostAgentBootstrapProductIntegrationState: Equatable, Sendable {
    case waitingForServer
    case ready(configRevision: UInt64)
    case degraded
}

/// Product-App boundary for publishing the immutable HostAgent projection.
/// It deliberately reloads the canonical on-disk catalog so an unsaved App
/// mutation can never become Agent input.
public final class HostAgentBootstrapProductIntegration: @unchecked Sendable {
    private let coordinator: HostAgentBootstrapPublicationCoordinator
    private let agentBuildID: String

    public convenience init() throws {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw HostAgentBootstrapProductLayoutError.applicationSupportUnavailable
        }
        try self.init(
            applicationSupportURL: applicationSupportURL,
            agentBuildID: Self.agentBuildID(from: Bundle.main.infoDictionary)
        )
    }

    init(applicationSupportURL: URL, agentBuildID: String) throws {
        guard HostAgentBootstrapConfiguration.validAgentBuildID(agentBuildID) else {
            throw HostAgentBootstrapProductIntegrationError.buildIdentifierUnavailable
        }
        coordinator = HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: applicationSupportURL
        )
        self.agentBuildID = agentBuildID
    }

    public func reconcileSavedCatalog(
        from catalogStore: DeviceCatalogStore
    ) -> HostAgentBootstrapProductIntegrationState {
        do {
            let catalog = try catalogStore.load()
            guard catalog.server?.isComplete == true else {
                return .waitingForServer
            }
            let outcome = try coordinator.publish(
                catalog: catalog,
                agentBuildID: agentBuildID
            )
            return .ready(configRevision: outcome.configRevision)
        } catch {
            return .degraded
        }
    }

    static func agentBuildID(from infoDictionary: [String: Any]?) throws -> String {
        guard let value = HostAgentBootstrapBuildIdentifier.resolve(
            from: infoDictionary
        ) else {
            throw HostAgentBootstrapProductIntegrationError.buildIdentifierUnavailable
        }
        return value
    }
}
