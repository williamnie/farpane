import Foundation

package enum HostMicrophoneAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

package enum HostMicrophoneAuthorizationRequestResult: Equatable, Sendable {
    case admitted
    case alreadyAuthorized
    case unavailable(HostMicrophoneAuthorizationStatus)
    case busy
}

package struct HostMicrophoneAuthorizationOperations: Sendable {
    package let observe:
        @Sendable () -> HostMicrophoneAuthorizationStatus
    package let requestAccess:
        @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

    package init(
        observe: @escaping @Sendable () -> HostMicrophoneAuthorizationStatus,
        requestAccess: @escaping @Sendable (
            @escaping @Sendable (Bool) -> Void
        ) -> Void
    ) {
        self.observe = observe
        self.requestAccess = requestAccess
    }
}

/// Owns the one user-initiated microphone authorization request. The backend
/// completion Boolean is never treated as authority; completion always
/// re-observes the non-prompting TCC state before product policy may change.
package final class HostMicrophoneAuthorizationOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let operations: HostMicrophoneAuthorizationOperations
    private var requestPending = false

    package init(operations: HostMicrophoneAuthorizationOperations) {
        self.operations = operations
    }

    package func authorizationStatus()
        -> HostMicrophoneAuthorizationStatus
    {
        operations.observe()
    }

    package func isRequestPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestPending
    }

    @discardableResult
    package func requestAuthorization(
        completion: @escaping @Sendable (
            HostMicrophoneAuthorizationStatus
        ) -> Void
    ) -> HostMicrophoneAuthorizationRequestResult {
        switch operations.observe() {
        case .authorized:
            return .alreadyAuthorized
        case .denied:
            return .unavailable(.denied)
        case .restricted:
            return .unavailable(.restricted)
        case .notDetermined:
            break
        }

        lock.lock()
        guard !requestPending else {
            lock.unlock()
            return .busy
        }
        requestPending = true
        lock.unlock()

        operations.requestAccess { [weak self] _ in
            guard let self else { return }
            let observed = self.operations.observe()
            self.lock.lock()
            guard self.requestPending else {
                self.lock.unlock()
                return
            }
            self.requestPending = false
            self.lock.unlock()
            completion(observed)
        }
        return .admitted
    }
}
