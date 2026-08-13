import Foundation

package final class HostAgentXPCPasswordService: @unchecked Sendable {
    package typealias Executor = @Sendable (
        _ action: HostAgentXPCPasswordAction,
        _ secret: inout Data,
        _ requestID: String
    ) throws -> Data?
    package typealias Reply = @Sendable (Data?, Data?) -> Void

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let identity: HostAgentXPCWireAgentIdentity
    private let execute: Executor
    private var busy = false
    private var invalidated = false
    private var seenRequestIDs: [String] = []

    package init(
        identity: HostAgentXPCWireAgentIdentity,
        queue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.password-commands",
            qos: .userInitiated
        ),
        execute: @escaping Executor
    ) {
        self.identity = identity
        self.queue = queue
        self.execute = execute
    }

    package func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    package func perform(
        requestData: Data,
        secretData: Data?,
        reply: @escaping Reply
    ) {
        let request: HostAgentXPCWirePasswordRequest
        do {
            request = try HostAgentXPCWirePasswordRequest.decode(requestData)
        } catch {
            reply(nil, nil)
            return
        }
        guard request.hostInstanceID == identity.hostInstanceID,
              request.agentBootID == identity.agentBootID,
              UInt64(secretData?.count ?? 0) == request.secretLength
        else {
            reply(nil, nil)
            return
        }

        lock.lock()
        guard !invalidated else {
            lock.unlock()
            reply(nil, nil)
            return
        }
        guard !seenRequestIDs.contains(request.requestID) else {
            lock.unlock()
            reply(
                responseData(
                    request: request,
                    status: .rejected,
                    detail: .duplicateRequest,
                    secretLength: 0
                ),
                nil
            )
            return
        }
        guard !busy else {
            lock.unlock()
            reply(
                responseData(
                    request: request,
                    status: .rejected,
                    detail: .busy,
                    secretLength: 0
                ),
                nil
            )
            return
        }
        if seenRequestIDs.count == 256 {
            seenRequestIDs.removeFirst()
        }
        seenRequestIDs.append(request.requestID)
        busy = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else {
                reply(nil, nil)
                return
            }
            var secret = secretData ?? Data()
            defer {
                if !secret.isEmpty {
                    secret.resetBytes(in: 0..<secret.count)
                    secret.removeAll(keepingCapacity: false)
                }
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }
            guard self.isActive() else {
                reply(nil, nil)
                return
            }
            do {
                let returnedSecret = try self.execute(
                    request.action,
                    &secret,
                    request.requestID
                )
                let returnedLength = UInt64(returnedSecret?.count ?? 0)
                guard returnedLength
                        <= UInt64(HostAgentXPCWirePasswordContract.maximumSecretBytes),
                      request.action == .revealTemporaryPassword
                        ? returnedLength > 0
                        : returnedLength == 0
                else {
                    reply(
                        self.responseData(
                            request: request,
                            status: .error,
                            detail: .coreFailure,
                            secretLength: 0
                        ),
                        nil
                    )
                    return
                }
                guard self.isActive() else {
                    reply(nil, nil)
                    return
                }
                reply(
                    self.responseData(
                        request: request,
                        status: .ok,
                        detail: .none,
                        secretLength: returnedLength
                    ),
                    returnedSecret
                )
            } catch {
                guard self.isActive() else {
                    reply(nil, nil)
                    return
                }
                let mapped = Self.map(error)
                reply(
                    self.responseData(
                        request: request,
                        status: mapped.status,
                        detail: mapped.detail,
                        secretLength: 0
                    ),
                    nil
                )
            }
        }
    }

    private func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !invalidated
    }

    private func responseData(
        request: HostAgentXPCWirePasswordRequest,
        status: HostAgentXPCPasswordStatus,
        detail: HostAgentXPCPasswordDetail,
        secretLength: UInt64
    ) -> Data? {
        try? HostAgentXPCWirePasswordResponse(
            request: request,
            status: status,
            detail: detail,
            secretLength: secretLength
        ).encoded()
    }

    private static func map(_ error: Error) -> (
        status: HostAgentXPCPasswordStatus,
        detail: HostAgentXPCPasswordDetail
    ) {
        guard let error = error as? HostControlError else {
            if error is HostAgentCoreRuntimeAccessError {
                return (.error, .coreUnavailable)
            }
            return (.error, .coreFailure)
        }
        switch error {
        case .permanentPassword:
            switch error.permanentPasswordFailure {
            case .empty: return (.rejected, .empty)
            case .tooShort: return (.rejected, .tooShort)
            case .tooLong: return (.rejected, .tooLong)
            case .outerWhitespace: return (.rejected, .outerWhitespace)
            case .invalidUTF8, .forbiddenCharacter:
                return (.rejected, .invalidCharacters)
            case .changeDisabled: return (.rejected, .changeDisabled)
            case .storage: return (.error, .storageFailure)
            case .unknown, .none: return (.error, .coreFailure)
            }
        case .snapshot, .snapshotDecode:
            return (.error, .temporaryPasswordUnavailable)
        case .command:
            return (.rejected, .coreFailure)
        default:
            return (.error, .coreFailure)
        }
    }
}
