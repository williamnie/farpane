import Foundation

package enum HostAgentCoreCommandResultDecodeOutcome:
    Equatable,
    Sendable
{
    case notCommandResult
    case malformed
    case foreignIdentity
    case decoded(HostAgentXPCWireCommandResult)
}

/// Strictly converts only the Core command-result envelope into the bounded
/// wire result type. Raw Core JSON remains outside the journal and XPC replay.
package enum HostAgentCoreCommandResultDecoder {
    package static func decode(
        _ event: HostCoreEvent,
        expectedHostInstanceID: String
    ) -> HostAgentCoreCommandResultDecodeOutcome {
        guard event.eventType == "commandResult" else {
            return .notCommandResult
        }
        guard let value = try? JSONSerialization.jsonObject(
                with: event.rawJSON
              ),
              let document = value as? [String: Any],
              Set(document.keys) == Set([
                "schemaVersion", "eventId", "eventType",
                "hostInstanceId", "sentAt", "payload",
              ]),
              HostAgentXPCWireEventContract.strictUInt64(
                document["schemaVersion"]
              ) == 1,
              let eventID = HostAgentXPCWireEventContract.strictUInt64(
                document["eventId"]
              ),
              eventID > 0,
              eventID == event.eventId,
              document["eventType"] as? String == "commandResult",
              let hostInstanceID = document["hostInstanceId"] as? String,
              HostAgentXPCWireHandshakeContract.validIdentifier(
                hostInstanceID
              ),
              hostInstanceID == event.hostInstanceId,
              let sentAt = HostAgentXPCWireEventContract.strictUInt64(
                document["sentAt"]
              ),
              sentAt == event.sentAt,
              HostAgentXPCWireEventContract.validTimestamp(sentAt),
              let payload = document["payload"] as? [String: Any],
              let result = try? HostAgentXPCWireCommandResult(
                document: payload
              )
        else {
            return .malformed
        }
        guard hostInstanceID == expectedHostInstanceID else {
            return .foreignIdentity
        }
        return .decoded(result)
    }
}
