import Foundation

/// Product command capability token. It binds an App activation epoch and
/// coherent projection generation to one reconnect-session route.
package struct HostAgentBackgroundCommandRoute: Equatable, Sendable {
    package let activationEpoch: UInt64
    package let projectionGeneration: UInt64
    package let reconnectRoute: HostAgentXPCReconnectCommandRoute

    package init(
        activationEpoch: UInt64,
        projectionGeneration: UInt64,
        reconnectRoute: HostAgentXPCReconnectCommandRoute
    ) {
        self.activationEpoch = activationEpoch
        self.projectionGeneration = projectionGeneration
        self.reconnectRoute = reconnectRoute
    }
}

package enum HostAgentBackgroundCommandAvailability:
    Equatable,
    Sendable
{
    case unavailable
    case available(
        route: HostAgentBackgroundCommandRoute,
        state: HostAgentXPCCommandIntentOwnerState
    )
}

/// Final typed policy shared by App-side command discovery and submission.
/// A limited Aqua session retains only exact disconnect for an existing
/// session; approval and every capability mutation fail closed.
package enum HostAgentBackgroundSessionCommandPolicy {
    package static func allows(
        _ intent: HostAgentXPCCommandIntent,
        payload: HostAgentXPCWireSnapshotPayload
    ) -> Bool {
        allows(
            intent.name,
            connectionID: intent.connectionID,
            payload: payload
        )
    }

    package static func allows(
        _ name: HostAgentXPCWireCommandName,
        connectionID: String,
        payload: HostAgentXPCWireSnapshotPayload
    ) -> Bool {
        switch (
            payload.sessionAvailability,
            payload.sessionUnavailableReason
        ) {
        case (.available, nil):
            return projectedConnectionID(
                for: name,
                payload: payload
            ) == connectionID
        case (.limited, .sessionUnavailable):
            return name == .disconnectSession
                && payload.activeSession?.connectionID == connectionID
        default:
            return false
        }
    }

    private static func projectedConnectionID(
        for name: HostAgentXPCWireCommandName,
        payload: HostAgentXPCWireSnapshotPayload
    ) -> String? {
        switch name {
        case .approveIncoming, .rejectIncoming:
            return payload.pendingApproval?.connectionID
        case .disableInputForActiveSession,
             .disableClipboardReadForActiveSession,
             .disableClipboardWriteForActiveSession,
             .disableClipboardForActiveSession,
             .disableAudioForActiveSession,
             .disconnectSession:
            return payload.activeSession?.connectionID
        }
    }
}
