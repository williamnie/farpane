@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundActivationOwnerTests: XCTestCase {
    func testEnableCreatesAndStartsExactlyOneFreshRuntime() {
        let factory = ActivationRuntimeFactory()
        let observations = ActivationViewRecorder()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            },
            observer: { observations.append($0) }
        )

        XCTAssertEqual(owner.snapshot().phase, .idle)
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(runtime.cancelCount, 0)
        XCTAssertEqual(
            owner.snapshot().phase,
            .monitoring(epoch: 1, readiness: runtime.readinessSnapshot())
        )
        XCTAssertEqual(
            observations.values.map(\.phase),
            [
                .starting(epoch: 1),
                .monitoring(
                    epoch: 1,
                    readiness: runtime.readinessSnapshot()
                ),
            ]
        )

        XCTAssertTrue(owner.apply(.hostEnabled))
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(observations.values.count, 2)
    }

    func testTypedHealthUpdatesOnlyCurrentActivationEpoch() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        runtime.emitHealthy(projectionGeneration: 1)

        guard case .monitoring(let epoch, let readiness) =
            owner.snapshot().phase
        else { return XCTFail("expected monitoring") }
        XCTAssertEqual(epoch, 1)
        XCTAssertTrue(readiness.isReady)
    }

    func testDisableCancelsBeforePublishingAndIgnoresLateHealth() {
        let factory = ActivationRuntimeFactory()
        let cancellationObserved = LockedValue(false)
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            },
            observer: { view in
                if view.phase == .disabled {
                    cancellationObserved.set(
                        factory.runtimes[0].cancelCount == 1
                    )
                }
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        XCTAssertTrue(owner.apply(.hostDisabled))
        let disabled = owner.snapshot()
        XCTAssertEqual(disabled.phase, .disabled)
        XCTAssertEqual(runtime.cancelCount, 1)
        XCTAssertTrue(cancellationObserved.value)

        runtime.emitHealthy(projectionGeneration: 1)
        XCTAssertEqual(owner.snapshot(), disabled)
    }

    func testReenableUsesFreshRuntimeAndRejectsOldEpochCallbacks() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let oldRuntime = factory.runtimes[0]
        XCTAssertTrue(owner.apply(.hostDisabled))

        XCTAssertTrue(owner.apply(.hostEnabled))
        let newRuntime = factory.runtimes[1]
        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(newRuntime.startCount, 1)
        guard case .monitoring(let epoch, _) = owner.snapshot().phase else {
            return XCTFail("expected replacement monitoring")
        }
        XCTAssertEqual(epoch, 3)

        oldRuntime.emitHealthy(projectionGeneration: 1)
        guard case .monitoring(_, let afterOld) = owner.snapshot().phase else {
            return XCTFail("expected monitoring after old callback")
        }
        XCTAssertFalse(afterOld.isReady)

        newRuntime.emitHealthy(projectionGeneration: 1)
        guard case .monitoring(_, let afterNew) = owner.snapshot().phase else {
            return XCTFail("expected monitoring after new callback")
        }
        XCTAssertTrue(afterNew.isReady)
    }

    func testApplicationTerminationIsTerminalAndCancelsCurrentRuntime() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        XCTAssertTrue(owner.apply(.applicationWillTerminate))
        XCTAssertEqual(runtime.cancelCount, 1)
        XCTAssertEqual(owner.snapshot().phase, .terminated)
        XCTAssertFalse(owner.apply(.hostEnabled))
        XCTAssertEqual(factory.makeCount, 1)
    }

    func testFactoryFailureIsSanitizedAndExplicitEnableCanRetry() {
        let factory = ActivationRuntimeFactory()
        factory.failNextCreation = true
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )

        XCTAssertFalse(owner.apply(.hostEnabled))
        XCTAssertEqual(owner.snapshot().phase, .failed(.runtimeCreation))
        XCTAssertEqual(factory.makeCount, 1)

        XCTAssertTrue(owner.apply(.hostEnabled))
        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(factory.runtimes[0].startCount, 1)
    }

    func testRejectedRuntimeStartCancelsAndFailsClosed() {
        let factory = ActivationRuntimeFactory()
        factory.nextStartResult = false
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )

        XCTAssertFalse(owner.apply(.hostEnabled))

        XCTAssertEqual(owner.snapshot().phase, .failed(.runtimeStartRejected))
        XCTAssertEqual(factory.runtimes[0].startCount, 1)
        XCTAssertEqual(factory.runtimes[0].cancelCount, 1)
    }

    func testRejectedHealthCancelsRuntimeAndCannotBeRevived() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]

        runtime.emitInvalid(projectionGeneration: 1)
        let failed = owner.snapshot()

        XCTAssertEqual(failed.phase, .failed(.runtimeHealthRejected))
        XCTAssertEqual(runtime.cancelCount, 1)
        runtime.emitHealthy(projectionGeneration: 2)
        XCTAssertEqual(owner.snapshot(), failed)
    }

    func testDisableDuringBlockingFactoryCancelsStaleRuntimeWithoutStart() {
        let factoryEntered = DispatchSemaphore(value: 0)
        let releaseFactory = DispatchSemaphore(value: 0)
        let runtimeHolder = LockedValue<ActivationFakeRuntime?>(nil)
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                let runtime = ActivationFakeRuntime(observer: observer)
                runtimeHolder.set(runtime)
                factoryEntered.signal()
                _ = releaseFactory.wait(timeout: .now() + 2)
                return runtime
            }
        )
        let enableResult = LockedValue<Bool?>(nil)
        let enableFinished = expectation(description: "enable finished")
        DispatchQueue.global().async {
            enableResult.set(owner.apply(.hostEnabled))
            enableFinished.fulfill()
        }
        XCTAssertEqual(factoryEntered.wait(timeout: .now() + 1), .success)

        XCTAssertTrue(owner.apply(.hostDisabled))
        releaseFactory.signal()
        wait(for: [enableFinished], timeout: 2)

        let runtime = try? XCTUnwrap(runtimeHolder.value)
        XCTAssertEqual(enableResult.value, false)
        XCTAssertEqual(runtime?.startCount, 0)
        XCTAssertEqual(runtime?.cancelCount, 1)
        XCTAssertEqual(owner.snapshot().phase, .disabled)
    }

    func testDisableDuringBlockingStartCannotBeOverwritten() {
        let startEntered = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let runtime = ActivationFakeRuntime(
            observer: { _ in },
            startAction: {
                startEntered.signal()
                _ = releaseStart.wait(timeout: .now() + 2)
                return true
            }
        )
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                runtime.replaceObserver(observer)
                return runtime
            }
        )
        let enableResult = LockedValue<Bool?>(nil)
        let enableFinished = expectation(description: "enable finished")
        DispatchQueue.global().async {
            enableResult.set(owner.apply(.hostEnabled))
            enableFinished.fulfill()
        }
        XCTAssertEqual(startEntered.wait(timeout: .now() + 1), .success)

        XCTAssertTrue(owner.apply(.hostDisabled))
        XCTAssertEqual(runtime.cancelCount, 1)
        releaseStart.signal()
        wait(for: [enableFinished], timeout: 2)

        XCTAssertEqual(enableResult.value, false)
        XCTAssertEqual(owner.snapshot().phase, .disabled)
    }

    func testReentrantDisableFromMonitoringObserverPreventsRuntimeStart() {
        let factory = ActivationRuntimeFactory()
        let ownerHolder = LockedValue<HostAgentBackgroundActivationOwner?>(nil)
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            },
            observer: { view in
                if case .monitoring = view.phase {
                    _ = ownerHolder.value?.apply(.hostDisabled)
                }
            }
        )
        ownerHolder.set(owner)

        XCTAssertFalse(owner.apply(.hostEnabled))

        XCTAssertEqual(factory.runtimes[0].startCount, 0)
        XCTAssertEqual(factory.runtimes[0].cancelCount, 1)
        XCTAssertEqual(owner.snapshot().phase, .disabled)
    }

    func testRegistrationRefreshOnlyTargetsCurrentMonitoringRuntime() {
        let factory = ActivationRuntimeFactory()
        let owner = HostAgentBackgroundActivationOwner(
            makeRuntime: { observer in
                try factory.make(observer: observer)
            }
        )

        owner.refreshRegistration()
        XCTAssertTrue(owner.apply(.hostEnabled))
        let runtime = factory.runtimes[0]
        owner.refreshRegistration()
        XCTAssertEqual(runtime.refreshCount, 1)

        XCTAssertTrue(owner.apply(.hostDisabled))
        owner.refreshRegistration()
        XCTAssertEqual(runtime.refreshCount, 1)
    }

    func testProductFactoryAndSourceRemainInertAndIndependentFromLegacyHost()
        throws
    {
        let owner = HostAgentBackgroundActivationOwner.makeProduct()
        XCTAssertEqual(owner.snapshot().phase, .idle)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundActivationOwner.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "HostAgentBackgroundRuntimeComposition.makeProduct"
        ))
        XCTAssertTrue(source.contains("reconnectOwner.start()"))
        XCTAssertTrue(source.contains("reconnectOwner.cancel()"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("SMAppService"))
        XCTAssertFalse(source.contains(".register()"))
        XCTAssertFalse(source.contains(".unregister()"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }
}

private enum ActivationTestError: Error {
    case creation
}

private final class ActivationRuntimeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ActivationFakeRuntime] = []
    private var creationCount = 0
    var failNextCreation = false
    var nextStartResult = true

    var runtimes: [ActivationFakeRuntime] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return creationCount
    }

    func make(
        observer: @escaping HostAgentBackgroundHealthAuthority.Observer
    ) throws -> HostAgentBackgroundActivationRuntime {
        lock.lock()
        creationCount += 1
        if failNextCreation {
            failNextCreation = false
            lock.unlock()
            throw ActivationTestError.creation
        }
        let startResult = nextStartResult
        nextStartResult = true
        let runtime = ActivationFakeRuntime(
            observer: observer,
            startAction: { startResult }
        )
        storage.append(runtime)
        lock.unlock()
        return runtime
    }
}

private final class ActivationFakeRuntime:
    HostAgentBackgroundActivationRuntime,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var healthAuthority: HostAgentBackgroundHealthAuthority
    private var startAction: @Sendable () -> Bool
    private var starts = 0
    private var cancels = 0
    private var refreshes = 0

    init(
        observer: @escaping HostAgentBackgroundHealthAuthority.Observer,
        startAction: @escaping @Sendable () -> Bool = { true }
    ) {
        self.startAction = startAction
        healthAuthority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled },
            observer: observer
        )
    }

    var startCount: Int { locked { starts } }
    var cancelCount: Int { locked { cancels } }
    var refreshCount: Int { locked { refreshes } }

    func readinessSnapshot() -> HostAgentBackgroundReadinessView {
        lock.lock()
        let authority = healthAuthority
        lock.unlock()
        return authority.snapshot()
    }

    func startMonitoring() -> Bool {
        lock.lock()
        starts += 1
        let action = startAction
        lock.unlock()
        return action()
    }

    func refreshRegistrationObservation() {
        lock.lock()
        refreshes += 1
        let authority = healthAuthority
        lock.unlock()
        authority.refreshRegistration()
    }

    func cancelMonitoring() {
        lock.lock()
        cancels += 1
        lock.unlock()
    }

    func replaceObserver(
        _ observer: @escaping HostAgentBackgroundHealthAuthority.Observer
    ) {
        lock.lock()
        healthAuthority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled },
            observer: observer
        )
        lock.unlock()
    }

    func emitHealthy(projectionGeneration: UInt64) {
        lock.lock()
        let authority = healthAuthority
        lock.unlock()
        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: projectionGeneration,
            handshake: .compatible,
            snapshot: .available,
            rendezvous: .registered
        ))
    }

    func emitInvalid(projectionGeneration: UInt64) {
        lock.lock()
        let authority = healthAuthority
        lock.unlock()
        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: projectionGeneration,
            handshake: .disconnected,
            snapshot: .available,
            rendezvous: .registered
        ))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ActivationViewRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentBackgroundActivationView] = []

    var values: [HostAgentBackgroundActivationView] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: HostAgentBackgroundActivationView) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
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
