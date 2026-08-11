import AVFoundation
import CoreBridge
import Foundation

/// Product adapter for microphone TCC. Only the foreground App calls
/// `requestAuthorization`; HostAgent uses the static non-prompting check.
final class HostMicrophoneAuthorizationAuthority: @unchecked Sendable {
    private let owner: HostMicrophoneAuthorizationOwner

    init(owner: HostMicrophoneAuthorizationOwner) {
        self.owner = owner
    }

    static func makeProduct() -> HostMicrophoneAuthorizationAuthority {
        HostMicrophoneAuthorizationAuthority(
            owner: HostMicrophoneAuthorizationOwner(
                operations: HostMicrophoneAuthorizationOperations(
                    observe: { @Sendable in
                        authorizationStatusWithoutPrompt()
                    },
                    requestAccess: { completion in
                        AVCaptureDevice.requestAccess(
                            for: .audio,
                            completionHandler: completion
                        )
                    }
                )
            )
        )
    }

    static func isAuthorizedWithoutPrompt() -> Bool {
        authorizationStatusWithoutPrompt() == .authorized
    }

    func authorizationStatus() -> HostMicrophoneAuthorizationStatus {
        owner.authorizationStatus()
    }

    func isRequestPending() -> Bool {
        owner.isRequestPending()
    }

    @discardableResult
    func requestAuthorization(
        completion: @escaping @Sendable (
            HostMicrophoneAuthorizationStatus
        ) -> Void
    ) -> HostMicrophoneAuthorizationRequestResult {
        owner.requestAuthorization(completion: completion)
    }

    private static func authorizationStatusWithoutPrompt()
        -> HostMicrophoneAuthorizationStatus
    {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorized:
            return .authorized
        @unknown default:
            return .restricted
        }
    }
}
