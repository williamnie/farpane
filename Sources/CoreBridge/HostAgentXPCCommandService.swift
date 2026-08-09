import Foundation

package struct HostAgentXPCCommandExecution: Equatable, Sendable {
    package let commandID: String
    package let name: HostAgentXPCWireCommandName
    package let connectionID: String

    fileprivate init(_ request: HostAgentXPCWireCommandRequest) {
        commandID = request.commandID
        name = request.name
        connectionID = request.connectionID
    }
}

/// A prepared execution whose body can only be claimed by the command service.
/// Preparation must not execute work.
package final class HostAgentXPCCommandQueueTicket: @unchecked Sendable {
    package typealias Start = @Sendable () -> Void

    private let lock = NSLock()
    private var startBody: Start?

    package init(start: @escaping Start) {
        startBody = start
    }

    package func claimPostReplyAction()
        -> HostAgentXPCCommandPostReplyAction?
    {
        lock.lock()
        guard let body = startBody else {
            lock.unlock()
            return nil
        }
        startBody = nil
        lock.unlock()
        return HostAgentXPCCommandPostReplyAction {
            body()
            return true
        }
    }
}

/// One-shot work that the transport invokes only after delivering the queued
/// acknowledgement. Copies share the same internal one-shot state.
package final class HostAgentXPCCommandPostReplyAction:
    @unchecked Sendable
{
    package typealias Body = @Sendable () -> Bool

    private let lock = NSLock()
    private var body: Body?

    package init(body: @escaping Body) {
        self.body = body
    }

    @discardableResult
    package func perform() -> Bool {
        lock.lock()
        guard let body else {
            lock.unlock()
            return false
        }
        self.body = nil
        lock.unlock()
        return body()
    }
}

/// The transport must deliver `data` before calling `performAfterReply()`.
package final class HostAgentXPCCommandPreparedResponse:
    @unchecked Sendable
{
    package let data: Data
    package let hasPostReplyAction: Bool
    private let postReplyAction: HostAgentXPCCommandPostReplyAction?

    fileprivate init(
        data: Data,
        postReplyAction: HostAgentXPCCommandPostReplyAction?
    ) {
        self.data = data
        self.postReplyAction = postReplyAction
        hasPostReplyAction = postReplyAction != nil
    }

    @discardableResult
    package func performAfterReply() -> Bool {
        postReplyAction?.perform() ?? true
    }
}

package enum HostAgentXPCCommandResultDeliveryOutcome:
    Equatable,
    Sendable
{
    case published
    case retainedForReplay
    case unchanged
    case unknownCommand
    case invalidated
}

/// Data-only command orchestration. It composes strict decoding, boot-bound
/// admission, two-phase queueing, queued acknowledgement and result replay.
/// Session gating and the transport selector remain separate later layers.
package final class HostAgentXPCCommandService: @unchecked Sendable {
    package typealias Clock = @Sendable () -> UInt64
    package typealias PrepareExecution = @Sendable (
        HostAgentXPCCommandExecution
    ) -> HostAgentXPCCommandQueueTicket?
    package typealias PublishResult = @Sendable (
        HostAgentXPCWireCommandResult
    ) -> Bool

    private let identity: HostAgentXPCWireAgentIdentity
    private let authority: HostAgentXPCCommandAdmissionAuthority
    private let prepareExecution: PrepareExecution
    private let publishResult: PublishResult
    private let nowUnixMilliseconds: Clock

    package init(
        identity: HostAgentXPCWireAgentIdentity,
        authority: HostAgentXPCCommandAdmissionAuthority,
        prepareExecution: @escaping PrepareExecution,
        publishResult: @escaping PublishResult,
        nowUnixMilliseconds: @escaping Clock
    ) {
        self.identity = identity
        self.authority = authority
        self.prepareExecution = prepareExecution
        self.publishResult = publishResult
        self.nowUnixMilliseconds = nowUnixMilliseconds
    }

    package func prepareResponse(
        for requestData: Data
    ) -> HostAgentXPCCommandPreparedResponse? {
        let request: HostAgentXPCWireCommandRequest
        do {
            request = try HostAgentXPCWireCommandRequest.decode(requestData)
        } catch {
            return nil
        }
        switch authority.reserve(request) {
        case .reserved(let reservation):
            let execution = HostAgentXPCCommandExecution(request)
            guard let ticket = prepareExecution(execution) else {
                _ = authority.cancelReservation(reservation)
                return nil
            }
            guard let postReplyAction = ticket.claimPostReplyAction() else {
                authority.invalidate()
                return nil
            }
            guard let responseData = queuedResponseData(for: request) else {
                _ = authority.cancelReservation(reservation)
                return nil
            }
            guard authority.markQueued(reservation) else { return nil }
            return HostAgentXPCCommandPreparedResponse(
                data: responseData,
                postReplyAction: postReplyAction
            )
        case .pendingQueue:
            return nil
        case .alreadyQueued:
            guard let responseData = queuedResponseData(for: request) else {
                return nil
            }
            return HostAgentXPCCommandPreparedResponse(
                data: responseData,
                postReplyAction: nil
            )
        case .replay(let result):
            guard let responseData = queuedResponseData(for: request) else {
                return nil
            }
            return HostAgentXPCCommandPreparedResponse(
                data: responseData,
                postReplyAction: HostAgentXPCCommandPostReplyAction {
                    self.publishResult(result)
                }
            )
        case .rejected:
            return nil
        }
    }

    /// Accepts a typed final result from the future execution adapter. The
    /// first publication failure keeps the result available for request replay.
    package func acceptResult(
        _ result: HostAgentXPCWireCommandResult
    ) -> HostAgentXPCCommandResultDeliveryOutcome {
        switch authority.recordResult(result) {
        case .recorded:
            return publishResult(result) ? .published : .retainedForReplay
        case .unchanged:
            return .unchanged
        case .unknownCommand:
            return .unknownCommand
        case .invalidated:
            return .invalidated
        }
    }

    private func queuedResponseData(
        for request: HostAgentXPCWireCommandRequest
    ) -> Data? {
        do {
            return try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
                for: request,
                identity: identity,
                sentAtUnixMilliseconds: nowUnixMilliseconds()
            ).encoded()
        } catch {
            return nil
        }
    }
}
