@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundApprovalNavigationOwnerTests: XCTestCase {
    func testConstructionIsInertUntilExplicitUserConfirmation() {
        let dependencies = ApprovalNavigationDependencies()
        let owner = makeOwner(dependencies)

        XCTAssertEqual(
            owner.snapshot(),
            HostAgentBackgroundApprovalNavigationView(
                generation: 0,
                phase: .idle,
                registration: nil
            )
        )
        XCTAssertEqual(dependencies.events, [])
    }

    func testConfirmedIntentRechecksRequiresApprovalBeforeNavigation() {
        let dependencies = ApprovalNavigationDependencies()
        dependencies.registration = .requiresApproval
        let publications = ApprovalNavigationViewRecorder()
        let owner = makeOwner(dependencies) { publications.append($0) }

        XCTAssertTrue(owner.apply(.openLoginItemsAfterUserConfirmation))

        XCTAssertEqual(dependencies.events, [.observe, .openLoginItems])
        XCTAssertEqual(
            publications.values.map(\.phase),
            [.checking, .navigationRequested]
        )
        XCTAssertEqual(owner.snapshot().registration, .requiresApproval)
    }

    func testDoesNotOpenSettingsWhenApprovalIsNotRequired() {
        for registration in [
            HostAgentBackgroundRegistrationStatus.notRegistered,
            .enabled,
        ] {
            let dependencies = ApprovalNavigationDependencies()
            dependencies.registration = registration
            let owner = makeOwner(dependencies)

            XCTAssertFalse(
                owner.apply(.openLoginItemsAfterUserConfirmation)
            )

            XCTAssertEqual(dependencies.events, [.observe])
            XCTAssertEqual(owner.snapshot().phase, .notRequired)
            XCTAssertEqual(owner.snapshot().registration, registration)
        }
    }

    func testUnavailableStatusFailsClosedWithoutOpeningSettings() {
        let dependencies = ApprovalNavigationDependencies()
        dependencies.registration = .serviceUnavailable
        let owner = makeOwner(dependencies)

        XCTAssertFalse(owner.apply(.openLoginItemsAfterUserConfirmation))

        XCTAssertEqual(dependencies.events, [.observe])
        XCTAssertEqual(
            owner.snapshot().phase,
            .failed(.serviceUnavailable)
        )
        XCTAssertEqual(owner.snapshot().registration, .serviceUnavailable)
    }

    func testConcurrentConfirmationIsRejectedWhileNavigationIsInFlight() {
        let openEntered = DispatchSemaphore(value: 0)
        let releaseOpen = DispatchSemaphore(value: 0)
        let dependencies = ApprovalNavigationDependencies()
        dependencies.registration = .requiresApproval
        dependencies.openAction = {
            openEntered.signal()
            _ = releaseOpen.wait(timeout: .now() + 2)
        }
        let owner = makeOwner(dependencies)
        let firstResult = ApprovalNavigationLockedValue<Bool?>(nil)
        let finished = expectation(description: "navigation finished")

        DispatchQueue.global().async {
            firstResult.set(
                owner.apply(.openLoginItemsAfterUserConfirmation)
            )
            finished.fulfill()
        }
        XCTAssertEqual(openEntered.wait(timeout: .now() + 1), .success)

        XCTAssertFalse(owner.apply(.openLoginItemsAfterUserConfirmation))
        XCTAssertEqual(owner.snapshot().phase, .checking)
        releaseOpen.signal()
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(firstResult.value, true)
        XCTAssertEqual(dependencies.events, [.observe, .openLoginItems])
        XCTAssertEqual(owner.snapshot().phase, .navigationRequested)
    }

    func testObserverCannotChainAnotherNavigationRequest() {
        let dependencies = ApprovalNavigationDependencies()
        dependencies.registration = .requiresApproval
        let ownerHolder = ApprovalNavigationLockedValue<
            HostAgentBackgroundApprovalNavigationOwner?
        >(nil)
        let chainedResult = ApprovalNavigationLockedValue<Bool?>(nil)
        let owner = makeOwner(dependencies) { view in
            if view.phase == .navigationRequested {
                chainedResult.set(
                    ownerHolder.value?.apply(
                        .openLoginItemsAfterUserConfirmation
                    )
                )
            }
        }
        ownerHolder.set(owner)

        XCTAssertTrue(owner.apply(.openLoginItemsAfterUserConfirmation))

        XCTAssertEqual(chainedResult.value, false)
        XCTAssertEqual(dependencies.events, [.observe, .openLoginItems])
        XCTAssertEqual(owner.snapshot().phase, .navigationRequested)
    }

    func testProductOwnerUsesReadOnlyStatusAndDedicatedSettingsAPI() throws {
        let owner = HostAgentBackgroundApprovalNavigationOwner.makeProduct()
        XCTAssertEqual(owner.snapshot().phase, .idle)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundApprovalNavigationOwner.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("HostAgentBackgroundServiceObserver"))
        XCTAssertTrue(source.contains(".observeRegistrationStatus()"))
        XCTAssertTrue(source.contains(
            "SMAppService.openSystemSettingsLoginItems()"
        ))
        XCTAssertFalse(source.contains("SMAppService.agent("))
        XCTAssertFalse(source.contains(".register()"))
        XCTAssertFalse(source.contains(".unregister()"))
        XCTAssertFalse(source.contains(
            "HostAgentBackgroundRegistrationMutationOwner"
        ))
        XCTAssertFalse(source.contains("HostAgentBackgroundActivationOwner"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("NSWorkspace"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    private func makeOwner(
        _ dependencies: ApprovalNavigationDependencies,
        observer: @escaping HostAgentBackgroundApprovalNavigationOwner.Observer = { _ in }
    ) -> HostAgentBackgroundApprovalNavigationOwner {
        HostAgentBackgroundApprovalNavigationOwner(
            observeRegistration: { dependencies.observe() },
            openLoginItems: { dependencies.openLoginItems() },
            observer: observer
        )
    }
}

private enum ApprovalNavigationEvent: Equatable {
    case observe
    case openLoginItems
}

private final class ApprovalNavigationDependencies: @unchecked Sendable {
    private let lock = NSLock()
    private var eventStorage: [ApprovalNavigationEvent] = []
    var registration: HostAgentBackgroundRegistrationStatus = .notRegistered
    var openAction: (() -> Void)?

    var events: [ApprovalNavigationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventStorage
    }

    func observe() -> HostAgentBackgroundRegistrationStatus {
        append(.observe)
        return registration
    }

    func openLoginItems() {
        append(.openLoginItems)
        openAction?()
    }

    private func append(_ event: ApprovalNavigationEvent) {
        lock.lock()
        eventStorage.append(event)
        lock.unlock()
    }
}

private final class ApprovalNavigationViewRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentBackgroundApprovalNavigationView] = []

    var values: [HostAgentBackgroundApprovalNavigationView] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: HostAgentBackgroundApprovalNavigationView) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class ApprovalNavigationLockedValue<Value>: @unchecked Sendable {
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
