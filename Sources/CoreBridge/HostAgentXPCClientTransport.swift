import CoreBridgeShim
import Foundation

package protocol HostAgentXPCSnapshotClientTransport: AnyObject, Sendable {
    func start(
        onInterruption: @escaping @Sendable () -> Void,
        onInvalidation: @escaping @Sendable () -> Void)
    func performHandshake(requestData: Data, reply: @escaping @Sendable (Data?) -> Void)
    func fetchSnapshot(requestData: Data, reply: @escaping @Sendable (Data?) -> Void)
    func fetchEvents(requestData: Data, reply: @escaping @Sendable (Data?) -> Void)
    func submitCommand(requestData: Data, reply: @escaping @Sendable (Data?) -> Void)
    func performPasswordOperation(
        requestData: Data, secretData: Data?, reply: @escaping @Sendable (Data?, Data?) -> Void)
    func invalidate()
}

extension HostAgentXPCSnapshotClientTransport {
    package func performPasswordOperation(
        requestData: Data, secretData: Data?, reply: @escaping @Sendable (Data?, Data?) -> Void
    ) { reply(nil, nil) }
}

package final class HostAgentXPCSnapshotClientConnectionTransport:
    HostAgentXPCSnapshotClientTransport, @unchecked Sendable
{
    private let connection: NSXPCConnection
    private let interface: NSXPCInterface

    package static func makeProduct() -> HostAgentXPCSnapshotClientConnectionTransport {
        let connection = NSXPCConnection(
            machServiceName: HostAgentXPCListenerFactory.machServiceName, options: [])
        return HostAgentXPCSnapshotClientConnectionTransport(connection: connection)
    }

    package init(connection: NSXPCConnection) {
        self.connection = connection
        interface = HostAgentXPCSnapshotInterfaceFactory.makeInterface()
    }

    package func start(
        onInterruption: @escaping @Sendable () -> Void,
        onInvalidation: @escaping @Sendable () -> Void
    ) {
        connection.remoteObjectInterface = interface
        connection.interruptionHandler = onInterruption
        connection.invalidationHandler = onInvalidation
        connection.resume()
    }

    package func performHandshake(requestData: Data, reply: @escaping @Sendable (Data?) -> Void) {
        invoke(reply: reply) { service, finish in
            service.performHandshake(requestData: requestData, reply: finish)
        }
    }

    package func fetchSnapshot(requestData: Data, reply: @escaping @Sendable (Data?) -> Void) {
        invoke(reply: reply) { service, finish in
            service.fetchSnapshot(requestData: requestData, reply: finish)
        }
    }

    package func fetchEvents(requestData: Data, reply: @escaping @Sendable (Data?) -> Void) {
        invoke(reply: reply) { service, finish in
            service.fetchEvents(requestData: requestData, reply: finish)
        }
    }

    package func submitCommand(requestData: Data, reply: @escaping @Sendable (Data?) -> Void) {
        invoke(reply: reply) { service, finish in
            service.submitCommand(requestData: requestData, reply: finish)
        }
    }

    package func performPasswordOperation(
        requestData: Data, secretData: Data?, reply: @escaping @Sendable (Data?, Data?) -> Void
    ) {
        let relay = HostAgentXPCPasswordReplyRelay(reply: reply)
        guard
            let service = connection.remoteObjectProxyWithErrorHandler({ _ in relay.finish(nil, nil)
                }) as? RDNHostAgentXPCPasswordService
        else {
            relay.finish(nil, nil)
            return
        }
        service.performPasswordOperation(requestData: requestData, secretData: secretData) {
            response, secret in relay.finish(response, secret)
        }
    }

    package func invalidate() { connection.invalidate() }

    private func invoke(
        reply: @escaping @Sendable (Data?) -> Void,
        body: (RDNHostAgentXPCCommandService, @escaping (Data?) -> Void) -> Void
    ) {
        let relay = HostAgentXPCSnapshotClientReplyRelay(reply: reply)
        guard
            let service = connection.remoteObjectProxyWithErrorHandler({ _ in relay.finish(nil) })
                as? RDNHostAgentXPCCommandService
        else {
            relay.finish(nil)
            return
        }
        body(service) { data in relay.finish(data) }
    }
}

private final class HostAgentXPCPasswordReplyRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: (@Sendable (Data?, Data?) -> Void)?

    init(reply: @escaping @Sendable (Data?, Data?) -> Void) { self.reply = reply }

    func finish(_ response: Data?, _ secret: Data?) {
        lock.lock()
        let reply = self.reply
        self.reply = nil
        lock.unlock()
        reply?(response, secret)
    }
}

private final class HostAgentXPCSnapshotClientReplyRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: (@Sendable (Data?) -> Void)?

    init(reply: @escaping @Sendable (Data?) -> Void) { self.reply = reply }

    func finish(_ data: Data?) {
        lock.lock()
        let reply = self.reply
        self.reply = nil
        lock.unlock()
        reply?(data)
    }
}
