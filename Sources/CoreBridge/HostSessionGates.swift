import CoreBridgeShim
import Foundation

package struct HostApprovalDecisionGate: Sendable {
    package private(set) var currentConnectionID: String?
    package private(set) var decisionInFlightConnectionID: String?
    private var lastNotifiedConnectionID: String?

    package init() {}

    /// Returns true once for each newly observed connection ID so the App can
    /// request local attention without repeating it on every snapshot poll.
    package mutating func observe(connectionID: String?) -> Bool {
        currentConnectionID = connectionID
        if decisionInFlightConnectionID != connectionID { decisionInFlightConnectionID = nil }
        guard let connectionID, connectionID != lastNotifiedConnectionID else { return false }
        lastNotifiedConnectionID = connectionID
        return true
    }

    /// Atomically accepts one local button action only for the current request.
    package mutating func beginDecision(connectionID: String) -> Bool {
        guard currentConnectionID == connectionID, decisionInFlightConnectionID == nil else {
            return false
        }
        decisionInFlightConnectionID = connectionID
        return true
    }

    package mutating func completeDecision(connectionID: String) {
        guard decisionInFlightConnectionID == connectionID else { return }
        decisionInFlightConnectionID = nil
    }

    package func isResolving(connectionID: String) -> Bool {
        decisionInFlightConnectionID == connectionID
    }

    package mutating func reset() {
        currentConnectionID = nil
        decisionInFlightConnectionID = nil
        lastNotifiedConnectionID = nil
    }
}

package enum HostSessionCommandIntent: Equatable, Sendable {
    case disable(HostSessionRevocableCapability)
    case disconnect
}

/// Serializes local active-session actions and keeps their completion bound to
/// the next authoritative Host snapshot. A successful C call only means the
/// command was queued; it never removes a capability or session optimistically.
package struct HostSessionCommandGate: Sendable {
    package private(set) var currentConnectionID: String?
    package private(set) var commandInFlightConnectionID: String?
    package private(set) var commandInFlightIntent: HostSessionCommandIntent?
    private var currentActiveCapabilities = Set<String>()

    package init() {}

    package mutating func observe(connectionID: String?, activeCapabilities: [String]) {
        if currentConnectionID != connectionID {
            commandInFlightConnectionID = nil
            commandInFlightIntent = nil
        }
        currentConnectionID = connectionID
        currentActiveCapabilities = connectionID == nil ? [] : Set(activeCapabilities)

        guard commandInFlightConnectionID == connectionID, let commandInFlightIntent else {
            if connectionID == nil {
                commandInFlightConnectionID = nil
                self.commandInFlightIntent = nil
            }
            return
        }
        if case .disable(let capability) = commandInFlightIntent,
            capability.snapshotCapabilityNames.isDisjoint(with: currentActiveCapabilities)
        {
            commandInFlightConnectionID = nil
            self.commandInFlightIntent = nil
        }
    }

    package mutating func begin(connectionID: String, intent: HostSessionCommandIntent) -> Bool {
        guard currentConnectionID == connectionID, commandInFlightConnectionID == nil,
            commandInFlightIntent == nil
        else { return false }
        if case .disable(let capability) = intent,
            !capability.snapshotCapabilityNames.isSubset(of: currentActiveCapabilities)
        {
            return false
        }
        commandInFlightConnectionID = connectionID
        commandInFlightIntent = intent
        return true
    }

    package mutating func complete(connectionID: String, intent: HostSessionCommandIntent) {
        guard commandInFlightConnectionID == connectionID, commandInFlightIntent == intent else {
            return
        }
        commandInFlightConnectionID = nil
        commandInFlightIntent = nil
    }

    package func isResolving(connectionID: String) -> Bool {
        commandInFlightConnectionID == connectionID && commandInFlightIntent != nil
    }

    package func resolvingIntent(connectionID: String) -> HostSessionCommandIntent? {
        commandInFlightConnectionID == connectionID ? commandInFlightIntent : nil
    }

    package mutating func reset() {
        currentConnectionID = nil
        currentActiveCapabilities = []
        commandInFlightConnectionID = nil
        commandInFlightIntent = nil
    }
}
