import Foundation

package enum HostAgentCoreCommandAction: Equatable, Sendable {
    case resolveApproval(HostApprovalDecision)
    case disable(HostSessionRevocableCapability)
    case disconnect
}

package struct HostAgentCoreCommandSubmission: Equatable, Sendable {
    package let commandID: String
    package let connectionID: String
    package let action: HostAgentCoreCommandAction

    fileprivate init(_ execution: HostAgentXPCCommandExecution) {
        commandID = execution.commandID
        connectionID = execution.connectionID
        action = Self.action(for: execution.name)
    }

    package init(validatedRequest: HostAgentXPCWireCommandRequest) {
        commandID = validatedRequest.commandID
        connectionID = validatedRequest.connectionID
        action = Self.action(for: validatedRequest.name)
    }

    private static func action(
        for name: HostAgentXPCWireCommandName
    ) -> HostAgentCoreCommandAction {
        switch name {
        case .approveIncoming:
            return .resolveApproval(.approve)
        case .rejectIncoming:
            return .resolveApproval(.reject)
        case .disableInputForActiveSession:
            return .disable(.keyboardAndMouse)
        case .disableClipboardForActiveSession:
            return .disable(.clipboard)
        case .disableAudioForActiveSession:
            return .disable(.systemAudio)
        case .disconnectSession:
            return .disconnect
        }
    }
}

package enum HostAgentXPCCommandImmediateDetail:
    String,
    Equatable,
    Sendable
{
    case coreRejected = "core-rejected"
    case coreUnavailable = "core-unavailable"
    case coreFailure = "core-failure"
    case agentStopping = "agent-stopping"
}

package enum HostAgentXPCCommandSubmissionOutcome: Equatable, Sendable {
    /// HostCore accepted the command and will emit the authoritative result.
    case awaitingCoreResult
    case rejected(HostAgentXPCCommandImmediateDetail)
    case failed(HostAgentXPCCommandImmediateDetail)
}

package enum HostAgentXPCCommandExecutionAdapterState:
    Equatable,
    Sendable
{
    case active
    case cancelled
    case invalidated
}

/// Process-lifetime serial execution seam for the six typed XPC commands.
/// Queue tickets remain inert until the XPC transport has delivered its ack.
/// HostCore access and result journaling are injected by later composition.
package final class HostAgentXPCCommandExecutionAdapter:
    @unchecked Sendable
{
    package typealias Submit = @Sendable (
        HostAgentCoreCommandSubmission
    ) -> HostAgentXPCCommandSubmissionOutcome
    package typealias ImmediateResultSink = @Sendable (
        HostAgentXPCWireCommandResult
    ) -> Void

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let pending = DispatchGroup()
    private let submit: Submit
    private let onImmediateResult: ImmediateResultSink
    private var state: HostAgentXPCCommandExecutionAdapterState = .active

    package init(
        queue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.commands",
            qos: .userInitiated
        ),
        submit: @escaping Submit,
        onImmediateResult: @escaping ImmediateResultSink
    ) {
        self.queue = queue
        self.submit = submit
        self.onImmediateResult = onImmediateResult
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        cancel()
    }

    package func stateSnapshot()
        -> HostAgentXPCCommandExecutionAdapterState
    {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    package func prepare(
        _ execution: HostAgentXPCCommandExecution
    ) -> HostAgentXPCCommandQueueTicket? {
        lock.lock()
        guard state == .active else {
            lock.unlock()
            return nil
        }
        let submission = HostAgentCoreCommandSubmission(execution)
        lock.unlock()
        return HostAgentXPCCommandQueueTicket { [self] in
            enqueue(submission)
        }
    }

    /// Stops accepting new preparation and waits only for work that had
    /// already entered the serial queue. Calling from that queue fails closed
    /// instead of deadlocking.
    package func cancelAndWait(timeout: DispatchTime) -> Bool {
        cancel()
        guard DispatchQueue.getSpecific(key: queueKey) == nil else {
            return false
        }
        return pending.wait(timeout: timeout) == .success
    }

    private func cancel() {
        lock.lock()
        if state == .active { state = .cancelled }
        lock.unlock()
    }

    private func enqueue(_ submission: HostAgentCoreCommandSubmission) {
        lock.lock()
        switch state {
        case .active:
            pending.enter()
            queue.async { [self] in
                defer { pending.leave() }
                handle(submit(submission), for: submission)
            }
            lock.unlock()
        case .cancelled:
            lock.unlock()
            publish(
                status: .error,
                detail: .agentStopping,
                for: submission
            )
        case .invalidated:
            lock.unlock()
        }
    }

    private func handle(
        _ outcome: HostAgentXPCCommandSubmissionOutcome,
        for submission: HostAgentCoreCommandSubmission
    ) {
        switch outcome {
        case .awaitingCoreResult:
            return
        case .rejected(let detail):
            publish(status: .rejected, detail: detail, for: submission)
        case .failed(let detail):
            publish(status: .error, detail: detail, for: submission)
        }
    }

    private func publish(
        status: HostAgentXPCWireCommandResultStatus,
        detail: HostAgentXPCCommandImmediateDetail,
        for submission: HostAgentCoreCommandSubmission
    ) {
        guard let result = try? HostAgentXPCWireCommandResult(
            commandID: submission.commandID,
            status: status,
            detail: detail.rawValue
        ) else {
            lock.lock()
            state = .invalidated
            lock.unlock()
            return
        }
        onImmediateResult(result)
    }
}
