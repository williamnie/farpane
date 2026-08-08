import ServiceManagement

/// Product-only, read-only lookup for the LaunchAgent embedded at
/// Contents/Library/LaunchAgents. Registration and settings mutations remain
/// separate operations that this type cannot perform.
package enum HostAgentBackgroundServiceObserver {
    package static let plistName =
        "io.rustdesknative.viewer.host-agent.plist"

    package static func observeRegistrationStatus()
        -> HostAgentBackgroundRegistrationStatus
    {
        HostAgentSMAppServiceStatusAdapter.map(
            SMAppService.agent(plistName: plistName).status
        )
    }
}
