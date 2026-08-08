@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundRegistrationUXOwnerTests: XCTestCase {
    func testConstructionIsInertAndRequestOnlyPublishesPersistencePrompt() {
        let dependencies = RegistrationUXDependencies()
        let owner = makeOwner(dependencies)

        XCTAssertEqual(owner.snapshot().phase, .idle)
        XCTAssertEqual(dependencies.events, [])
        XCTAssertTrue(owner.apply(.requestBackgroundRegistration))

        guard case .awaitingConfirmation(let prompt) =
            owner.snapshot().phase
        else { return XCTFail("expected persistence confirmation") }
        XCTAssertEqual(prompt.kind, .backgroundPersistence)
        XCTAssertEqual(prompt.title, "允许 FarPane 在后台接受连接？")
        XCTAssertTrue(prompt.message.contains("即使退出 FarPane"))
        XCTAssertTrue(prompt.message.contains("当前已登录用户"))
        XCTAssertEqual(prompt.confirmButtonTitle, "允许后台连接")
        XCTAssertEqual(prompt.cancelButtonTitle, "取消")
        XCTAssertEqual(dependencies.events, [])
    }

    func testCancelPersistencePromptPerformsNoMutation() {
        let dependencies = RegistrationUXDependencies()
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.apply(.requestBackgroundRegistration))

        XCTAssertTrue(owner.apply(.cancelBackgroundRegistration))

        XCTAssertEqual(owner.snapshot().phase, .cancelled)
        XCTAssertNil(owner.snapshot().registration)
        XCTAssertEqual(dependencies.events, [])
    }

    func testConfirmationIsRejectedWithoutMatchingPromptPhase() {
        let dependencies = RegistrationUXDependencies()
        let owner = makeOwner(dependencies)

        XCTAssertFalse(owner.apply(.confirmBackgroundRegistration))
        XCTAssertFalse(owner.apply(.confirmApprovalNavigation))
        XCTAssertEqual(owner.snapshot().phase, .idle)
        XCTAssertEqual(dependencies.events, [])
    }

    func testConfirmedPersistenceRunsRegistrationOnceWithoutStartingAgent() {
        let dependencies = RegistrationUXDependencies()
        dependencies.registrationResult = (
            true,
            registrationView(phase: .registered, registration: .enabled)
        )
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.apply(.requestBackgroundRegistration))

        XCTAssertTrue(owner.apply(.confirmBackgroundRegistration))

        XCTAssertEqual(dependencies.events, [.register])
        XCTAssertEqual(owner.snapshot().phase, .registered)
        XCTAssertEqual(owner.snapshot().registration, .enabled)
    }

    func testRequiresApprovalPublishesSecondExplicitPromptWithoutNavigation() {
        let dependencies = RegistrationUXDependencies()
        dependencies.registrationResult = (
            true,
            registrationView(
                phase: .requiresApproval,
                registration: .requiresApproval
            )
        )
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.apply(.requestBackgroundRegistration))

        XCTAssertTrue(owner.apply(.confirmBackgroundRegistration))

        guard case .awaitingConfirmation(let prompt) =
            owner.snapshot().phase
        else { return XCTFail("expected approval confirmation") }
        XCTAssertEqual(prompt.kind, .loginItemsApproval)
        XCTAssertTrue(prompt.message.contains("登录项与扩展"))
        XCTAssertTrue(prompt.message.contains("不代表已可被连接"))
        XCTAssertEqual(prompt.confirmButtonTitle, "打开登录项设置")
        XCTAssertEqual(prompt.cancelButtonTitle, "稍后")
        XCTAssertEqual(owner.snapshot().registration, .requiresApproval)
        XCTAssertEqual(dependencies.events, [.register])
    }

    func testApprovalConfirmationInvokesOnlyDedicatedNavigationOwner() {
        let dependencies = RegistrationUXDependencies()
        dependencies.registrationResult = (
            true,
            registrationView(
                phase: .requiresApproval,
                registration: .requiresApproval
            )
        )
        dependencies.navigationResult = (
            true,
            approvalView(
                phase: .navigationRequested,
                registration: .requiresApproval
            )
        )
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.apply(.requestBackgroundRegistration))
        XCTAssertTrue(owner.apply(.confirmBackgroundRegistration))

        XCTAssertTrue(owner.apply(.confirmApprovalNavigation))

        XCTAssertEqual(dependencies.events, [.register, .navigate])
        XCTAssertEqual(owner.snapshot().phase, .navigationRequested)
        XCTAssertEqual(owner.snapshot().registration, .requiresApproval)
    }

    func testCancelApprovalPromptDoesNotNavigateOrClaimRegistration() {
        let dependencies = RegistrationUXDependencies()
        dependencies.registrationResult = (
            true,
            registrationView(
                phase: .requiresApproval,
                registration: .requiresApproval
            )
        )
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.apply(.requestBackgroundRegistration))
        XCTAssertTrue(owner.apply(.confirmBackgroundRegistration))

        XCTAssertTrue(owner.apply(.cancelApprovalNavigation))

        XCTAssertEqual(dependencies.events, [.register])
        XCTAssertEqual(owner.snapshot().phase, .cancelled)
        XCTAssertEqual(owner.snapshot().registration, .requiresApproval)
    }

    func testRegistrationFailureIsSanitizedAndDoesNotNavigate() {
        let dependencies = RegistrationUXDependencies()
        dependencies.registrationResult = (
            false,
            registrationView(
                phase: .failed(
                    intent: .registerBackgroundAgent,
                    failure: .invalidCodeSignature
                ),
                registration: nil
            )
        )
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.apply(.requestBackgroundRegistration))

        XCTAssertFalse(owner.apply(.confirmBackgroundRegistration))

        XCTAssertEqual(
            owner.snapshot().phase,
            .failed(.registration(.invalidCodeSignature))
        )
        XCTAssertEqual(dependencies.events, [.register])
    }

    func testNavigationStatusDriftDoesNotClaimRequest() {
        let dependencies = RegistrationUXDependencies()
        dependencies.registrationResult = (
            true,
            registrationView(
                phase: .requiresApproval,
                registration: .requiresApproval
            )
        )
        dependencies.navigationResult = (
            false,
            approvalView(
                phase: .notRequired,
                registration: .enabled
            )
        )
        let owner = makeOwner(dependencies)
        XCTAssertTrue(owner.apply(.requestBackgroundRegistration))
        XCTAssertTrue(owner.apply(.confirmBackgroundRegistration))

        XCTAssertFalse(owner.apply(.confirmApprovalNavigation))

        XCTAssertEqual(owner.snapshot().phase, .approvalNoLongerRequired)
        XCTAssertEqual(owner.snapshot().registration, .enabled)
        XCTAssertEqual(dependencies.events, [.register, .navigate])
    }

    func testConcurrentOrReentrantIntentCannotSkipConfirmation() {
        let registerEntered = DispatchSemaphore(value: 0)
        let releaseRegister = DispatchSemaphore(value: 0)
        let dependencies = RegistrationUXDependencies()
        dependencies.registrationAction = {
            registerEntered.signal()
            _ = releaseRegister.wait(timeout: .now() + 2)
        }
        dependencies.registrationResult = (
            true,
            registrationView(phase: .registered, registration: .enabled)
        )
        let ownerHolder = RegistrationUXLockedValue<
            HostAgentBackgroundRegistrationUXOwner?
        >(nil)
        let reentrantResult = RegistrationUXLockedValue<Bool?>(nil)
        let owner = makeOwner(dependencies) { view in
            if view.phase == .registered {
                reentrantResult.set(
                    ownerHolder.value?.apply(.requestBackgroundRegistration)
                )
            }
        }
        ownerHolder.set(owner)
        XCTAssertTrue(owner.apply(.requestBackgroundRegistration))
        let confirmResult = RegistrationUXLockedValue<Bool?>(nil)
        let finished = expectation(description: "registration finished")
        DispatchQueue.global().async {
            confirmResult.set(owner.apply(.confirmBackgroundRegistration))
            finished.fulfill()
        }
        XCTAssertEqual(registerEntered.wait(timeout: .now() + 1), .success)

        XCTAssertFalse(owner.apply(.confirmApprovalNavigation))
        releaseRegister.signal()
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(confirmResult.value, true)
        XCTAssertEqual(reentrantResult.value, false)
        XCTAssertEqual(dependencies.events, [.register])
        XCTAssertEqual(owner.snapshot().phase, .registered)
    }

    func testProductCompositionRemainsInertAndIndependentFromLegacyHost()
        throws
    {
        let owner = HostAgentBackgroundRegistrationUXOwner.makeProduct()
        XCTAssertEqual(owner.snapshot().phase, .idle)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundRegistrationUXOwner.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "HostAgentBackgroundRegistrationMutationOwner.makeProduct()"
        ))
        XCTAssertTrue(source.contains(
            "HostAgentBackgroundApprovalNavigationOwner.makeProduct()"
        ))
        XCTAssertTrue(source.contains(".registerBackgroundAgent"))
        XCTAssertTrue(source.contains(
            ".openLoginItemsAfterUserConfirmation"
        ))
        XCTAssertFalse(source.contains("SMAppService"))
        XCTAssertFalse(source.contains("HostAgentBackgroundActivationOwner"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("NSAlert"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    private func makeOwner(
        _ dependencies: RegistrationUXDependencies,
        observer: @escaping HostAgentBackgroundRegistrationUXOwner.Observer = { _ in }
    ) -> HostAgentBackgroundRegistrationUXOwner {
        HostAgentBackgroundRegistrationUXOwner(
            performRegistration: { dependencies.register() },
            performApprovalNavigation: { dependencies.navigate() },
            observer: observer
        )
    }

    private func registrationView(
        phase: HostAgentBackgroundRegistrationMutationPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) -> HostAgentBackgroundRegistrationMutationView {
        HostAgentBackgroundRegistrationMutationView(
            generation: 2,
            phase: phase,
            registration: registration
        )
    }

    private func approvalView(
        phase: HostAgentBackgroundApprovalNavigationPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) -> HostAgentBackgroundApprovalNavigationView {
        HostAgentBackgroundApprovalNavigationView(
            generation: 2,
            phase: phase,
            registration: registration
        )
    }
}

private enum RegistrationUXEvent: Equatable {
    case register
    case navigate
}

private final class RegistrationUXDependencies: @unchecked Sendable {
    private let lock = NSLock()
    private var eventStorage: [RegistrationUXEvent] = []
    var registrationAction: (() -> Void)?
    var registrationResult: (
        Bool,
        HostAgentBackgroundRegistrationMutationView
    ) = (
        false,
        HostAgentBackgroundRegistrationMutationView(
            generation: 2,
            phase: .failed(
                intent: .registerBackgroundAgent,
                failure: .serviceUnavailable
            ),
            registration: .serviceUnavailable
        )
    )
    var navigationResult: (
        Bool,
        HostAgentBackgroundApprovalNavigationView
    ) = (
        false,
        HostAgentBackgroundApprovalNavigationView(
            generation: 2,
            phase: .failed(.serviceUnavailable),
            registration: .serviceUnavailable
        )
    )

    var events: [RegistrationUXEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventStorage
    }

    func register() -> (
        Bool,
        HostAgentBackgroundRegistrationMutationView
    ) {
        append(.register)
        registrationAction?()
        return registrationResult
    }

    func navigate() -> (
        Bool,
        HostAgentBackgroundApprovalNavigationView
    ) {
        append(.navigate)
        return navigationResult
    }

    private func append(_ event: RegistrationUXEvent) {
        lock.lock()
        eventStorage.append(event)
        lock.unlock()
    }
}

private final class RegistrationUXLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
