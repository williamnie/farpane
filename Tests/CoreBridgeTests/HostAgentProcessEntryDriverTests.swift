import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentProcessEntryDriverTests: XCTestCase {
    func testProductStateOwnerStartsWithFreshAuthorities() throws {
        let first = try HostAgentProcessEntryStateOwner()
        let second = try HostAgentProcessEntryStateOwner()

        XCTAssertFalse(first.eventState === second.eventState)
        XCTAssertFalse(first.snapshotState === second.snapshotState)
        XCTAssertFalse(first.mediaState === second.mediaState)
        XCTAssertFalse(first.concurrencyState === second.concurrencyState)
        XCTAssertEqual(first.eventState.snapshot().latestSequence, 0)
        XCTAssertEqual(first.eventState.snapshot().records.count, 0)
        XCTAssertEqual(first.snapshotState.snapshot().status, .waiting)
        XCTAssertNil(first.snapshotState.snapshot().projection)
        XCTAssertEqual(first.mediaState.snapshot().acceptedControlCount, 0)
        XCTAssertFalse(first.mediaState.snapshot().cancelled)
        XCTAssertEqual(
            first.concurrencyState.snapshot(),
            .init(
                acceptedObservations: 0, deliveredObservations: 0, pendingObservations: 0,
                lastSourceGeneration: 0, bound: false, failed: false, cancelled: false))
    }

    func testDriverCreatesOneOwnerAndRunsOnceWithSameEligibility() throws {
        let eligibility = HostAgentProcessEntryEligibility(
            buildIdentifier: "202608090002", signingChannel: .localDevelopment)
        let expectedOwner = try HostAgentProcessEntryStateOwner()
        var ownerFactoryCalls = 0
        var runnerCalls = 0

        let result = HostAgentProcessEntryDriver.run(
            eligibility: eligibility,
            makeStateOwner: {
                ownerFactoryCalls += 1
                return expectedOwner
            },
            run: { receivedEligibility, receivedOwner in
                runnerCalls += 1
                XCTAssertEqual(receivedEligibility, eligibility)
                XCTAssertTrue(receivedOwner === expectedOwner)
                XCTAssertTrue(receivedOwner.eventState === expectedOwner.eventState)
                XCTAssertTrue(receivedOwner.snapshotState === expectedOwner.snapshotState)
                XCTAssertTrue(receivedOwner.mediaState === expectedOwner.mediaState)
                XCTAssertTrue(receivedOwner.concurrencyState === expectedOwner.concurrencyState)
                return .stopped
            })

        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(ownerFactoryCalls, 1)
        XCTAssertEqual(runnerCalls, 1)
    }

    func testStateConstructionFailureIsSanitizedAndSkipsRunner() {
        var runnerCalls = 0

        let result = HostAgentProcessEntryDriver.run(
            eligibility: HostAgentProcessEntryEligibility(
                buildIdentifier: "dev-2", signingChannel: .localDevelopment),
            makeStateOwner: { throw TestError.stateUnavailable },
            run: { _, _ in
                runnerCalls += 1
                return .stopped
            })

        XCTAssertEqual(result, .internalFailure)
        XCTAssertEqual(runnerCalls, 0)
    }

    func testForgedEligibilityFailsClosedBeforeCreatingState() {
        for invalidBuildIdentifier in ["", " bad", "bad/build"] {
            var ownerFactoryCalls = 0
            var runnerCalls = 0

            let result = HostAgentProcessEntryDriver.run(
                eligibility: HostAgentProcessEntryEligibility(
                    buildIdentifier: invalidBuildIdentifier, signingChannel: .localDevelopment),
                makeStateOwner: {
                    ownerFactoryCalls += 1
                    return try HostAgentProcessEntryStateOwner()
                },
                run: { _, _ in
                    runnerCalls += 1
                    return .stopped
                })

            XCTAssertEqual(result, .internalFailure)
            XCTAssertEqual(ownerFactoryCalls, 0)
            XCTAssertEqual(runnerCalls, 0)
        }
    }

}

private enum TestError: Error { case stateUnavailable }
