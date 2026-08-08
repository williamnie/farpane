@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundRegistrationMutationOwnerTests: XCTestCase {
    func testConstructionIsInertUntilExplicitIntent() {
        let dependencies = RegistrationMutationDependencies()
        let owner = makeOwner(dependencies)

        XCTAssertEqual(
            owner.snapshot(),
            HostAgentBackgroundRegistrationMutationView(
                generation: 0,
                phase: .idle,
                registration: nil
            )
        )
        XCTAssertEqual(dependencies.events, [])
    }

    func testRegisterRechecksIdentityBeforeCallingService() {
        let failures: [(HostAgentRegistrationIdentityStatus,
                        HostAgentBackgroundRegistrationMutationFailure)] = [
            (.invalidLaunchAgent, .invalidLaunchAgent),
            (.invalidApplication, .invalidApplication),
            (.invalidCodeSignature, .invalidCodeSignature),
            (
                .distributionNotarizationRequired(buildIdentifier: "42"),
                .distributionNotarizationRequired
            ),
        ]

        for (identity, expectedFailure) in failures {
            let dependencies = RegistrationMutationDependencies()
            dependencies.identity = identity
            let owner = makeOwner(dependencies)

            XCTAssertFalse(owner.apply(.registerBackgroundAgent))
            XCTAssertEqual(
                owner.snapshot().phase,
                .failed(
                    intent: .registerBackgroundAgent,
                    failure: expectedFailure
                )
            )
            XCTAssertNil(owner.snapshot().registration)
            XCTAssertEqual(dependencies.events, [.assessIdentity])
        }
    }

    func testRegisterPublishesAuthoritativeEnabledStatus() {
        let dependencies = RegistrationMutationDependencies()
        dependencies.observedStatus = .enabled
        let publications = RegistrationMutationViewRecorder()
        let owner = makeOwner(dependencies) { publications.append($0) }

        XCTAssertTrue(owner.apply(.registerBackgroundAgent))

        XCTAssertEqual(
            dependencies.events,
            [.assessIdentity, .register, .observe]
        )
        XCTAssertEqual(
            publications.values.map(\.phase),
            [.registering, .registered]
        )
        XCTAssertEqual(owner.snapshot().registration, .enabled)
    }

    func testRegisterDoesNotTreatCallReturnAsReady() {
        let dependencies = RegistrationMutationDependencies()
        dependencies.observedStatus = .notRegistered
        let owner = makeOwner(dependencies)

        XCTAssertFalse(owner.apply(.registerBackgroundAgent))

        XCTAssertEqual(
            owner.snapshot().phase,
            .failed(
                intent: .registerBackgroundAgent,
                failure: .registrationNotEffective
            )
        )
        XCTAssertEqual(owner.snapshot().registration, .notRegistered)
    }

    func testRegisterSurfacesRequiresApprovalAsDistinctNonReadyState() {
        let dependencies = RegistrationMutationDependencies()
        dependencies.registerError = RegistrationMutationTestError.rejected
        dependencies.observedStatus = .requiresApproval
        let owner = makeOwner(dependencies)

        XCTAssertTrue(owner.apply(.registerBackgroundAgent))

        XCTAssertEqual(owner.snapshot().phase, .requiresApproval)
        XCTAssertEqual(owner.snapshot().registration, .requiresApproval)
    }

    func testRegisterFailsClosedWhenServiceStatusIsUnavailable() {
        let dependencies = RegistrationMutationDependencies()
        dependencies.observedStatus = .serviceUnavailable
        let owner = makeOwner(dependencies)

        XCTAssertFalse(owner.apply(.registerBackgroundAgent))

        XCTAssertEqual(
            owner.snapshot().phase,
            .failed(
                intent: .registerBackgroundAgent,
                failure: .serviceUnavailable
            )
        )
        XCTAssertEqual(owner.snapshot().registration, .serviceUnavailable)
    }

    func testUnregisterDoesNotRequireRegistrationEligibility() {
        let dependencies = RegistrationMutationDependencies()
        dependencies.identity = .invalidCodeSignature
        dependencies.unregisterError = RegistrationMutationTestError.rejected
        dependencies.observedStatus = .notRegistered
        let owner = makeOwner(dependencies)

        XCTAssertTrue(owner.apply(.unregisterBackgroundAgent))

        XCTAssertEqual(dependencies.events, [.unregister, .observe])
        XCTAssertEqual(owner.snapshot().phase, .unregistered)
        XCTAssertEqual(owner.snapshot().registration, .notRegistered)
    }

    func testUnregisterFailsClosedWhileRegistrationRemainsEnabled() {
        let dependencies = RegistrationMutationDependencies()
        dependencies.observedStatus = .enabled
        let owner = makeOwner(dependencies)

        XCTAssertFalse(owner.apply(.unregisterBackgroundAgent))

        XCTAssertEqual(
            owner.snapshot().phase,
            .failed(
                intent: .unregisterBackgroundAgent,
                failure: .unregistrationNotEffective
            )
        )
        XCTAssertEqual(owner.snapshot().registration, .enabled)
    }

    func testConcurrentIntentIsRejectedWhileMutationIsInFlight() {
        let registerEntered = DispatchSemaphore(value: 0)
        let releaseRegister = DispatchSemaphore(value: 0)
        let dependencies = RegistrationMutationDependencies()
        dependencies.registerAction = {
            registerEntered.signal()
            _ = releaseRegister.wait(timeout: .now() + 2)
        }
        dependencies.observedStatus = .enabled
        let owner = makeOwner(dependencies)
        let registerResult = RegistrationMutationLockedValue<Bool?>(nil)
        let finished = expectation(description: "register finished")

        DispatchQueue.global().async {
            registerResult.set(owner.apply(.registerBackgroundAgent))
            finished.fulfill()
        }
        XCTAssertEqual(registerEntered.wait(timeout: .now() + 1), .success)

        XCTAssertFalse(owner.apply(.unregisterBackgroundAgent))
        XCTAssertEqual(owner.snapshot().phase, .registering)
        releaseRegister.signal()
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(registerResult.value, true)
        XCTAssertEqual(dependencies.events, [.assessIdentity, .register, .observe])
        XCTAssertEqual(owner.snapshot().phase, .registered)
    }

    func testObserverCannotChainAnImplicitMutation() {
        let dependencies = RegistrationMutationDependencies()
        dependencies.observedStatus = .enabled
        let ownerHolder = RegistrationMutationLockedValue<
            HostAgentBackgroundRegistrationMutationOwner?
        >(nil)
        let chainedResult = RegistrationMutationLockedValue<Bool?>(nil)
        let owner = makeOwner(dependencies) { view in
            if view.phase == .registered {
                chainedResult.set(
                    ownerHolder.value?.apply(.unregisterBackgroundAgent)
                )
            }
        }
        ownerHolder.set(owner)

        XCTAssertTrue(owner.apply(.registerBackgroundAgent))

        XCTAssertEqual(chainedResult.value, false)
        XCTAssertEqual(
            dependencies.events,
            [.assessIdentity, .register, .observe]
        )
        XCTAssertEqual(owner.snapshot().phase, .registered)
    }

    func testProductOwnerUsesOnlyFixedServiceAndRemainsInert() throws {
        let owner = HostAgentBackgroundRegistrationMutationOwner.makeProduct()
        XCTAssertEqual(owner.snapshot().phase, .idle)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundRegistrationMutationOwner.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "HostAgentRegistrationIdentityGate.assessMainBundle()"
        ))
        XCTAssertTrue(source.contains(
            "HostAgentBackgroundServiceObserver.plistName"
        ))
        XCTAssertTrue(source.contains("service.register()"))
        XCTAssertTrue(source.contains("service.unregister()"))
        XCTAssertTrue(source.contains(
            "HostAgentSMAppServiceStatusAdapter.map(service.status)"
        ))
        XCTAssertFalse(source.contains("openSystemSettingsLoginItems"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    private func makeOwner(
        _ dependencies: RegistrationMutationDependencies,
        observer: @escaping HostAgentBackgroundRegistrationMutationOwner.Observer = { _ in }
    ) -> HostAgentBackgroundRegistrationMutationOwner {
        HostAgentBackgroundRegistrationMutationOwner(
            assessIdentity: { dependencies.assessIdentity() },
            register: { try dependencies.register() },
            unregister: { try dependencies.unregister() },
            observeRegistration: { dependencies.observe() },
            observer: observer
        )
    }
}

private enum RegistrationMutationTestError: Error {
    case rejected
}

private enum RegistrationMutationEvent: Equatable {
    case assessIdentity
    case register
    case unregister
    case observe
}

private final class RegistrationMutationDependencies: @unchecked Sendable {
    private let lock = NSLock()
    private var eventStorage: [RegistrationMutationEvent] = []
    var identity: HostAgentRegistrationIdentityStatus =
        .localDevelopmentEligible(buildIdentifier: "42")
    var observedStatus: HostAgentBackgroundRegistrationStatus = .notRegistered
    var registerError: Error?
    var unregisterError: Error?
    var registerAction: (() -> Void)?

    var events: [RegistrationMutationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventStorage
    }

    func assessIdentity() -> HostAgentRegistrationIdentityStatus {
        append(.assessIdentity)
        return identity
    }

    func register() throws {
        append(.register)
        registerAction?()
        if let registerError { throw registerError }
    }

    func unregister() throws {
        append(.unregister)
        if let unregisterError { throw unregisterError }
    }

    func observe() -> HostAgentBackgroundRegistrationStatus {
        append(.observe)
        return observedStatus
    }

    private func append(_ event: RegistrationMutationEvent) {
        lock.lock()
        eventStorage.append(event)
        lock.unlock()
    }
}

private final class RegistrationMutationViewRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentBackgroundRegistrationMutationView] = []

    var values: [HostAgentBackgroundRegistrationMutationView] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: HostAgentBackgroundRegistrationMutationView) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class RegistrationMutationLockedValue<Value>: @unchecked Sendable {
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
