import Foundation

package enum HostAgentXPCCommandProcessOwnerState: Equatable, Sendable {
    case waitingForRuntime
    case waitingForIdentity
    case active
    case cancelled
    case invalidated
}

package enum HostAgentXPCCommandCoreEventRoutingOutcome:
    Equatable,
    Sendable
{
    case forwarded
    case consumed(HostAgentXPCCommandResultDeliveryOutcome)
    case dropped
    case invalidated
}

/// Boot-lifetime composition for command admission, serial Core execution and
/// typed result journaling. It deliberately owns no XPC connection: every
/// admitted connection receives the same service snapshot for this boot.
package final class HostAgentXPCCommandProcessOwner: @unchecked Sendable {
    package typealias RuntimeSubmission = @Sendable (
        HostAgentCoreCommandSubmission
    ) -> HostAgentXPCCommandSubmissionOutcome
    package typealias PasswordSubmission = HostAgentXPCPasswordService.Executor
    package typealias Clock = @Sendable () -> UInt64
    package typealias EventConsumer = @Sendable (HostCoreEvent) -> Void
    package typealias InvalidationCallback = @Sendable () -> Void

    private let lock = NSLock()
    private let agentProcessIdentity: HostAgentXPCWireAgentProcessIdentity
    private let eventState: HostAgentEventState
    private let nowUnixMilliseconds: Clock
    private let onNonCommandEvent: EventConsumer
    private let onInvalidationRequired: InvalidationCallback
    private var state: HostAgentXPCCommandProcessOwnerState =
        .waitingForRuntime
    private var runtimeSubmission: RuntimeSubmission?
    private var passwordSubmission: PasswordSubmission?
    private var identity: HostAgentXPCWireAgentIdentity?
    private var admissionAuthority: HostAgentXPCCommandAdmissionAuthority?
    private var executionAdapter: HostAgentXPCCommandExecutionAdapter?
    private var commandService: HostAgentXPCCommandService?
    private var passwordService: HostAgentXPCPasswordService?
    private var invalidationDelivered = false

    package init(
        agentProcessIdentity: HostAgentXPCWireAgentProcessIdentity,
        eventState: HostAgentEventState,
        nowUnixMilliseconds: @escaping Clock,
        onNonCommandEvent: @escaping EventConsumer,
        onInvalidationRequired: @escaping InvalidationCallback
    ) throws {
        self.agentProcessIdentity = agentProcessIdentity
        self.eventState = eventState
        self.nowUnixMilliseconds = nowUnixMilliseconds
        self.onNonCommandEvent = onNonCommandEvent
        self.onInvalidationRequired = onInvalidationRequired
    }

    deinit {
        _ = cancelAndWait(timeout: .now())
    }

    package func stateSnapshot() -> HostAgentXPCCommandProcessOwnerState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Installs the only typed Core submission seam before identity/listener
    /// admission. Rebinding is rejected so commands cannot change executors
    /// during one Agent boot.
    @discardableResult
    package func bindRuntimeSubmission(
        _ submission: @escaping RuntimeSubmission
    ) -> Bool {
        lock.lock()
        guard state == .waitingForRuntime,
              runtimeSubmission == nil
        else {
            let shouldInvalidate = state == .waitingForIdentity
                || state == .active
            lock.unlock()
            if shouldInvalidate { invalidate() }
            return false
        }
        runtimeSubmission = submission
        state = .waitingForIdentity
        lock.unlock()
        return true
    }

    @discardableResult
    package func bindPasswordSubmission(
        _ submission: @escaping PasswordSubmission
    ) -> Bool {
        lock.lock()
        guard state == .waitingForIdentity,
              passwordSubmission == nil
        else {
            let shouldInvalidate = state == .active
            lock.unlock()
            if shouldInvalidate { invalidate() }
            return false
        }
        passwordSubmission = submission
        lock.unlock()
        return true
    }

    /// Creates exactly one boot/Host-bound admission authority, serial adapter
    /// and service. The same Host is idempotent; any replacement is terminal.
    package func bindIdentity(
        hostInstanceID: String
    ) -> HostAgentXPCProcessIdentityBindResult {
        lock.lock()
        switch state {
        case .active:
            guard identity?.hostInstanceID == hostInstanceID else {
                lock.unlock()
                invalidate()
                return .rejected(.conflictingHostInstance)
            }
            lock.unlock()
            return .unchanged
        case .waitingForIdentity:
            break
        case .waitingForRuntime:
            lock.unlock()
            invalidate()
            return .rejected(.invalidated)
        case .cancelled, .invalidated:
            lock.unlock()
            return .rejected(.invalidated)
        }

        let newIdentity: HostAgentXPCWireAgentIdentity
        let newAuthority: HostAgentXPCCommandAdmissionAuthority
        do {
            newIdentity = try agentProcessIdentity.bind(
                hostInstanceID: hostInstanceID
            )
            newAuthority = try HostAgentXPCCommandAdmissionAuthority(
                identity: newIdentity
            )
        } catch {
            lock.unlock()
            invalidate()
            return .rejected(.invalidHostInstance)
        }

        let newAdapter = HostAgentXPCCommandExecutionAdapter(
            submit: { [weak self] submission in
                self?.submitToRuntime(submission)
                    ?? .failed(.coreUnavailable)
            },
            onImmediateResult: { [weak self] result in
                self?.acceptImmediateResult(result)
            }
        )
        let newService = HostAgentXPCCommandService(
            identity: newIdentity,
            authority: newAuthority,
            prepareExecution: { [weak newAdapter] execution in
                newAdapter?.prepare(execution)
            },
            publishResult: { [weak self] result in
                self?.publishResult(
                    result,
                    hostInstanceID: newIdentity.hostInstanceID
                ) ?? false
            },
            nowUnixMilliseconds: nowUnixMilliseconds
        )
        let newPasswordService = passwordSubmission.map {
            HostAgentXPCPasswordService(
                identity: newIdentity,
                execute: $0
            )
        }
        identity = newIdentity
        admissionAuthority = newAuthority
        executionAdapter = newAdapter
        commandService = newService
        passwordService = newPasswordService
        state = .active
        lock.unlock()
        return .bound
    }

    package func commandServiceSnapshot() -> HostAgentXPCCommandService? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return nil }
        return commandService
    }

    package func passwordServiceSnapshot() -> HostAgentXPCPasswordService? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return nil }
        return passwordService
    }

    /// Command results are consumed before the generic event journal. Ordinary
    /// events retain the pre-existing downstream route while the runtime is
    /// starting; no event is delivered after terminal teardown.
    @discardableResult
    package func consumeCoreEvent(
        _ event: HostCoreEvent
    ) -> HostAgentXPCCommandCoreEventRoutingOutcome {
        if event.eventType != "commandResult" {
            lock.lock()
            let shouldForward = state != .cancelled && state != .invalidated
            lock.unlock()
            guard shouldForward else { return .dropped }
            onNonCommandEvent(event)
            return .forwarded
        }

        guard let service = commandServiceSnapshot() else {
            lock.lock()
            let terminal = state == .cancelled || state == .invalidated
            lock.unlock()
            if !terminal { invalidate() }
            return .invalidated
        }
        switch service.consumeCoreResultEvent(event) {
        case .notCommandResult, .malformed, .foreignIdentity:
            invalidate()
            return .invalidated
        case .delivered(let outcome):
            switch outcome {
            case .published, .unchanged:
                return .consumed(outcome)
            case .retainedForReplay, .unknownCommand, .invalidated:
                invalidate()
                return .invalidated
            }
        }
    }

    /// Terminally closes command admission without requesting process/XPC
    /// invalidation. Existing queued Core work is boundedly drained.
    @discardableResult
    package func cancelAndWait(timeout: DispatchTime) -> Bool {
        lock.lock()
        if state == .cancelled || state == .invalidated {
            let adapter = executionAdapter
            lock.unlock()
            return adapter?.cancelAndWait(timeout: timeout) ?? true
        }
        state = .cancelled
        let authority = admissionAuthority
        let adapter = executionAdapter
        let passwordService = self.passwordService
        commandService = nil
        self.passwordService = nil
        lock.unlock()

        authority?.invalidate()
        passwordService?.invalidate()
        let drained = adapter?.cancelAndWait(timeout: timeout) ?? true
        lock.lock()
        if state == .cancelled {
            runtimeSubmission = nil
            passwordSubmission = nil
        }
        lock.unlock()
        return drained
    }

    /// Terminal contradiction path. Its external invalidation callback is
    /// delivered at most once and always outside the owner lock.
    package func invalidate() {
        lock.lock()
        guard state != .invalidated else {
            lock.unlock()
            return
        }
        state = .invalidated
        runtimeSubmission = nil
        let authority = admissionAuthority
        let adapter = executionAdapter
        let passwordService = self.passwordService
        commandService = nil
        self.passwordService = nil
        let callback: InvalidationCallback?
        if invalidationDelivered {
            callback = nil
        } else {
            invalidationDelivered = true
            callback = onInvalidationRequired
        }
        lock.unlock()

        authority?.invalidate()
        passwordService?.invalidate()
        _ = adapter?.cancelAndWait(timeout: .now())
        callback?()
    }

    private func submitToRuntime(
        _ submission: HostAgentCoreCommandSubmission
    ) -> HostAgentXPCCommandSubmissionOutcome {
        lock.lock()
        guard (state == .active || state == .cancelled),
              let runtimeSubmission
        else {
            lock.unlock()
            return .failed(.coreUnavailable)
        }
        lock.unlock()
        return runtimeSubmission(submission)
    }

    private func acceptImmediateResult(
        _ result: HostAgentXPCWireCommandResult
    ) {
        guard let service = commandServiceSnapshot() else { return }
        switch service.acceptResult(result) {
        case .published, .unchanged:
            return
        case .retainedForReplay, .unknownCommand, .invalidated:
            invalidate()
        }
    }

    private func publishResult(
        _ result: HostAgentXPCWireCommandResult,
        hostInstanceID: String
    ) -> Bool {
        let journalResult = eventState.ingestCommandResult(
            result,
            hostInstanceID: hostInstanceID,
            sentAtUnixMilliseconds: nowUnixMilliseconds()
        )
        switch journalResult {
        case .accepted, .unchanged:
            return true
        case .rejected:
            invalidate()
            return false
        }
    }
}
