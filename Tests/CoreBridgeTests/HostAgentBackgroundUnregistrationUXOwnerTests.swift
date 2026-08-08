@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundUnregistrationUXOwnerTests: XCTestCase {
    func testConstructionIsInertAndRequestPublishesRequiredDisclosure() {
        let dependencies = UnregistrationUXDependencies()
        let owner = makeOwner(dependencies)

        XCTAssertEqual(owner.snapshot().phase, .idle)
        XCTAssertEqual(dependencies.calls, 0)
        XCTAssertTrue(owner.apply(.requestBackgroundUnregistration))

        guard case .awaitingConfirmation(let prompt) = owner.snapshot().phase
        else { return XCTFail("expected unregistration confirmation") }
        XCTAssertEqual(prompt.title, "关闭后台连接？")
        XCTAssertTrue(prompt.message.contains("停止后台组件"))
        XCTAssertTrue(prompt.message.contains("不再接受新的远程连接"))
        XCTAssertTrue(prompt.message.contains("设备身份和服务器配置会保留"))
        XCTAssertEqual(prompt.confirmButtonTitle, "关闭后台连接")
        XCTAssertEqual(prompt.cancelButtonTitle, "取消")
        XCTAssertEqual(dependencies.calls, 0)
    }

    func testCancellationNeverCallsMutation() {
        let dependencies = UnregistrationUXDependencies()
        let owner = makeOwner(dependencies)

        XCTAssertFalse(owner.apply(.confirmBackgroundUnregistration))
        XCTAssertTrue(owner.apply(.requestBackgroundUnregistration))
        XCTAssertTrue(owner.apply(.cancelBackgroundUnregistration))

        XCTAssertEqual(owner.snapshot().phase, .cancelled)
        XCTAssertEqual(dependencies.calls, 0)
        XCTAssertFalse(owner.apply(.confirmBackgroundUnregistration))
    }

    func testConfirmationPublishesUnregisteringBeforeExactSuccess() {
        let dependencies = UnregistrationUXDependencies()
        dependencies.result = (
            true,
            mutationView(phase: .unregistered, registration: .notRegistered)
        )
        let recorder = UnregistrationUXRecorder()
        let owner = makeOwner(dependencies) { recorder.append($0.phase) }
        XCTAssertTrue(owner.apply(.requestBackgroundUnregistration))
        let prompt = owner.snapshot().phase

        XCTAssertTrue(owner.apply(.confirmBackgroundUnregistration))

        XCTAssertEqual(
            recorder.phases,
            [prompt, .unregistering, .unregistered]
        )
        XCTAssertEqual(owner.snapshot().registration, .notRegistered)
        XCTAssertEqual(dependencies.calls, 1)
    }

    func testTypedMutationFailuresRemainDistinct() {
        for failure in [
            HostAgentBackgroundRegistrationMutationFailure
                .serviceUnavailable,
            .unregistrationNotEffective,
        ] {
            let dependencies = UnregistrationUXDependencies()
            dependencies.result = (
                false,
                mutationView(
                    phase: .failed(
                        intent: .unregisterBackgroundAgent,
                        failure: failure
                    ),
                    registration: failure == .serviceUnavailable
                        ? .serviceUnavailable
                        : .enabled
                )
            )
            let owner = makeOwner(dependencies)
            XCTAssertTrue(owner.apply(.requestBackgroundUnregistration))

            XCTAssertFalse(owner.apply(.confirmBackgroundUnregistration))
            XCTAssertEqual(owner.snapshot().phase, .failed(.mutation(failure)))
            XCTAssertEqual(dependencies.calls, 1)
        }
    }

    func testContradictoryMutationResultsFailClosed() {
        let results: [(Bool, HostAgentBackgroundRegistrationMutationView)] = [
            (
                false,
                mutationView(
                    phase: .unregistered,
                    registration: .notRegistered
                )
            ),
            (
                true,
                mutationView(
                    phase: .failed(
                        intent: .unregisterBackgroundAgent,
                        failure: .unregistrationNotEffective
                    ),
                    registration: .enabled
                )
            ),
            (
                false,
                mutationView(
                    phase: .failed(
                        intent: .registerBackgroundAgent,
                        failure: .registrationNotEffective
                    ),
                    registration: .notRegistered
                )
            ),
            (
                true,
                mutationView(phase: .unregistering, registration: nil)
            ),
        ]

        for result in results {
            let dependencies = UnregistrationUXDependencies()
            dependencies.result = result
            let owner = makeOwner(dependencies)
            XCTAssertTrue(owner.apply(.requestBackgroundUnregistration))

            XCTAssertFalse(owner.apply(.confirmBackgroundUnregistration))
            XCTAssertEqual(owner.snapshot().phase, .failed(.invalidMutationResult))
        }
    }

    func testBlockingMutationRejectsConcurrentAndReentrantIntents() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let dependencies = UnregistrationUXDependencies()
        dependencies.onCall = {
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        dependencies.result = (
            true,
            mutationView(phase: .unregistered, registration: .notRegistered)
        )
        let ownerHolder = UnregistrationUXLockedValue<
            HostAgentBackgroundUnregistrationUXOwner?
        >(nil)
        let reentrant = UnregistrationUXLockedValue<Bool?>(nil)
        let owner = makeOwner(dependencies) { phase in
            if phase.phase == .unregistering {
                reentrant.set(
                    ownerHolder.value?.apply(
                        .requestBackgroundUnregistration
                    )
                )
            }
        }
        ownerHolder.set(owner)
        XCTAssertTrue(owner.apply(.requestBackgroundUnregistration))
        let finished = expectation(description: "unregistration finished")

        DispatchQueue.global().async {
            _ = owner.apply(.confirmBackgroundUnregistration)
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(reentrant.value, false)
        XCTAssertFalse(owner.apply(.cancelBackgroundUnregistration))
        XCTAssertFalse(owner.apply(.requestBackgroundUnregistration))
        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(owner.snapshot().phase, .unregistered)
    }

    func testProductCompositionRequiresCallerOwnedMutationAuthority() throws {
        let mutationOwner = HostAgentBackgroundRegistrationMutationOwner(
            assessIdentity: { .invalidApplication },
            register: {},
            unregister: {},
            observeRegistration: { .notRegistered }
        )
        let owner = HostAgentBackgroundUnregistrationUXOwner.makeProduct(
            mutationOwner: mutationOwner
        )
        XCTAssertEqual(owner.snapshot().phase, .idle)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundUnregistrationUXOwner.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("mutationOwner.apply("))
        XCTAssertTrue(source.contains(".unregisterBackgroundAgent"))
        XCTAssertFalse(source.contains(
            "HostAgentBackgroundRegistrationMutationOwner.makeProduct()"
        ))
        XCTAssertFalse(source.contains("SMAppService"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("HostControlClient"))
    }

    func testSharedMutationAuthorityRejectsOpposingProductOperation() {
        let dependencies = SharedMutationDependencies()
        let mutationOwner = HostAgentBackgroundRegistrationMutationOwner(
            assessIdentity: {
                .localDevelopmentEligible(buildIdentifier: "42")
            },
            register: { dependencies.register() },
            unregister: { dependencies.unregister() },
            observeRegistration: { .enabled }
        )
        let registrationOwner =
            HostAgentBackgroundRegistrationUXOwner.makeProduct(
                mutationOwner: mutationOwner,
                performMigrationPreparation: {
                    (
                        true,
                        HostAgentLegacyHostMigrationCoordinatorView(
                            phase: .readyForRegistration
                        )
                    )
                }
            )
        let unregistrationOwner =
            HostAgentBackgroundUnregistrationUXOwner.makeProduct(
                mutationOwner: mutationOwner
            )
        XCTAssertTrue(registrationOwner.apply(
            .requestBackgroundRegistration
        ))
        let registrationFinished = expectation(
            description: "registration finished"
        )

        DispatchQueue.global().async {
            _ = registrationOwner.apply(.confirmBackgroundRegistration)
            registrationFinished.fulfill()
        }
        XCTAssertEqual(
            dependencies.registerEntered.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertTrue(unregistrationOwner.apply(
            .requestBackgroundUnregistration
        ))
        XCTAssertFalse(unregistrationOwner.apply(
            .confirmBackgroundUnregistration
        ))
        XCTAssertEqual(
            unregistrationOwner.snapshot().phase,
            .failed(.invalidMutationResult)
        )
        XCTAssertEqual(dependencies.unregisterCalls, 0)

        dependencies.releaseRegister.signal()
        wait(for: [registrationFinished], timeout: 2)
        XCTAssertEqual(registrationOwner.snapshot().phase, .registered)
    }
}

private func makeOwner(
    _ dependencies: UnregistrationUXDependencies,
    observer: @escaping HostAgentBackgroundUnregistrationUXOwner.Observer = { _ in }
) -> HostAgentBackgroundUnregistrationUXOwner {
    HostAgentBackgroundUnregistrationUXOwner(
        performUnregistration: { dependencies.perform() },
        observer: observer
    )
}

private func mutationView(
    phase: HostAgentBackgroundRegistrationMutationPhase,
    registration: HostAgentBackgroundRegistrationStatus?
) -> HostAgentBackgroundRegistrationMutationView {
    HostAgentBackgroundRegistrationMutationView(
        generation: 1,
        phase: phase,
        registration: registration
    )
}

private final class UnregistrationUXDependencies: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    var result = (
        false,
        mutationView(
            phase: .failed(
                intent: .unregisterBackgroundAgent,
                failure: .serviceUnavailable
            ),
            registration: .serviceUnavailable
        )
    )
    var onCall: (() -> Void)?

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func perform() -> (Bool, HostAgentBackgroundRegistrationMutationView) {
        lock.lock()
        callCount += 1
        lock.unlock()
        onCall?()
        return result
    }
}

private final class UnregistrationUXRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentBackgroundUnregistrationUXPhase] = []

    var phases: [HostAgentBackgroundUnregistrationUXPhase] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ phase: HostAgentBackgroundUnregistrationUXPhase) {
        lock.lock()
        storage.append(phase)
        lock.unlock()
    }
}

private final class SharedMutationDependencies: @unchecked Sendable {
    let registerEntered = DispatchSemaphore(value: 0)
    let releaseRegister = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var unregisterCount = 0

    var unregisterCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return unregisterCount
    }

    func register() {
        registerEntered.signal()
        _ = releaseRegister.wait(timeout: .now() + 2)
    }

    func unregister() {
        lock.lock()
        unregisterCount += 1
        lock.unlock()
    }
}

private final class UnregistrationUXLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

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
