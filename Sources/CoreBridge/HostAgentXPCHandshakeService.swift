import CoreBridgeShim
import Foundation

package enum HostAgentXPCHandshakeInterfaceFactory {
    package static var handshakeSelectorName: String {
        NSStringFromSelector(
            #selector(
                RDNHostAgentXPCHandshakeService.performHandshake(
                    requestData:reply:
                )
            )
        )
    }

    package static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: RDNHostAgentXPCHandshakeService.self)
    }
}

/// Handles only the bounded negotiation document. Owning and accepting a peer
/// remain separate responsibilities of a later authenticated runtime.
package final class HostAgentXPCHandshakeHandler:
    NSObject,
    RDNHostAgentXPCHandshakeService,
    @unchecked Sendable
{
    package typealias Clock = @Sendable () -> UInt64

    private let identity: HostAgentXPCWireAgentIdentity
    private let nowUnixMilliseconds: Clock

    package init(
        identity: HostAgentXPCWireAgentIdentity,
        nowUnixMilliseconds: @escaping Clock
    ) {
        self.identity = identity
        self.nowUnixMilliseconds = nowUnixMilliseconds
    }

    package func response(for requestData: Data) -> Data? {
        do {
            let request = try HostAgentXPCWireHandshakeRequest.decode(requestData)
            let response = try HostAgentXPCWireHandshakeNegotiator.makeResponse(
                for: request,
                identity: identity,
                sentAtUnixMilliseconds: nowUnixMilliseconds()
            )
            return try response.encoded()
        } catch {
            return nil
        }
    }

    package func performHandshake(
        requestData: Data,
        reply: @escaping (Data?) -> Void
    ) {
        reply(response(for: requestData))
    }
}
