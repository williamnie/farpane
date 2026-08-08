import Foundation

/// Process-lifetime bootstrap authority held before touching Rust Host state.
/// Retaining this context retains the single-writer lease; dropping it releases
/// the lease through ownership. A Host runtime must retain the context for its
/// entire lifetime and consume configuration through that same owner.
public final class HostAgentBootstrapContext: @unchecked Sendable {
    public let agentBootID: UUID
    public let configuration: HostAgentBootstrapConfiguration

    public var leaseRecord: HostAgentSingleWriterLeaseRecord {
        lease.record
    }

    private let lease: HostAgentSingleWriterLease

    private init(
        agentBootID: UUID,
        configuration: HostAgentBootstrapConfiguration,
        lease: HostAgentSingleWriterLease
    ) {
        self.agentBootID = agentBootID
        self.configuration = configuration
        self.lease = lease
    }

    public static func prepare() throws -> HostAgentBootstrapContext {
        let configuration = try HostAgentBootstrapLaunchPreflight().prepare()
        return try prepare(configuration: configuration)
    }

    /// Package-only entry bridge. The expected identifier has already passed
    /// the installed application identity gate and must match the immutable
    /// projection before this process may acquire its single-writer lease.
    package static func prepare(
        expectedAgentBuildID: String
    ) throws -> HostAgentBootstrapContext {
        let configuration = try HostAgentBootstrapLaunchPreflight().prepare(
            expectedAgentBuildID: expectedAgentBuildID
        )
        return try prepare(configuration: configuration)
    }

    private static func prepare(
        configuration: HostAgentBootstrapConfiguration
    ) throws -> HostAgentBootstrapContext {
        let agentBootID = UUID()
        let lease = try HostAgentSingleWriterLease.acquire(
            configuration: configuration,
            agentBootID: agentBootID
        )
        return HostAgentBootstrapContext(
            agentBootID: agentBootID,
            configuration: configuration,
            lease: lease
        )
    }

    static func prepare(
        applicationSupportURL: URL,
        expectedAgentBuildID: String,
        agentBootID: UUID
    ) throws -> HostAgentBootstrapContext {
        let configuration = try HostAgentBootstrapLaunchPreflight(
            applicationSupportURL: applicationSupportURL
        ).prepare(expectedAgentBuildID: expectedAgentBuildID)
        let lease = try HostAgentSingleWriterLease.acquire(
            directoryURL: HostAgentBootstrapProductLayout.directoryURL(
                applicationSupportURL: applicationSupportURL
            ),
            configuration: configuration,
            agentBootID: agentBootID
        )
        return HostAgentBootstrapContext(
            agentBootID: agentBootID,
            configuration: configuration,
            lease: lease
        )
    }
}
