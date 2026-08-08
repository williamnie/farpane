import ServiceManagement

/// Read-only bridge from the macOS ServiceManagement observation into the
/// product's independent registration evidence. This adapter deliberately
/// cannot construct, register, unregister or open settings for a service.
package enum HostAgentSMAppServiceStatusAdapter {
    package static func map(
        _ status: SMAppService.Status
    ) -> HostAgentBackgroundRegistrationStatus {
        switch status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .serviceUnavailable
        @unknown default:
            return .serviceUnavailable
        }
    }
}
