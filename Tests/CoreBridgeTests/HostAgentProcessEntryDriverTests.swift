@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentProcessEntryDriverTests: XCTestCase {
    func testProductStateOwnerStartsWithThreeFreshAuthorities() throws {
        let first = try HostAgentProcessEntryStateOwner()
        let second = try HostAgentProcessEntryStateOwner()

        XCTAssertFalse(first.eventState === second.eventState)
        XCTAssertFalse(first.snapshotState === second.snapshotState)
        XCTAssertFalse(first.mediaState === second.mediaState)
        XCTAssertEqual(first.eventState.snapshot().latestSequence, 0)
        XCTAssertEqual(first.eventState.snapshot().records.count, 0)
        XCTAssertEqual(first.snapshotState.snapshot().status, .waiting)
        XCTAssertNil(first.snapshotState.snapshot().projection)
        XCTAssertEqual(first.mediaState.snapshot().acceptedControlCount, 0)
        XCTAssertFalse(first.mediaState.snapshot().cancelled)
    }

    func testDriverCreatesOneOwnerAndRunsOnceWithSameEligibility() throws {
        let eligibility = HostAgentProcessEntryEligibility(
            buildIdentifier: "202608090002",
            signingChannel: .localDevelopment
        )
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
                return .stopped
            }
        )

        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(ownerFactoryCalls, 1)
        XCTAssertEqual(runnerCalls, 1)
    }

    func testStateConstructionFailureIsSanitizedAndSkipsRunner() {
        var runnerCalls = 0

        let result = HostAgentProcessEntryDriver.run(
            eligibility: HostAgentProcessEntryEligibility(
                buildIdentifier: "dev-2",
                signingChannel: .localDevelopment
            ),
            makeStateOwner: {
                throw TestError.stateUnavailable
            },
            run: { _, _ in
                runnerCalls += 1
                return .stopped
            }
        )

        XCTAssertEqual(result, .internalFailure)
        XCTAssertEqual(runnerCalls, 0)
    }

    func testForgedEligibilityFailsClosedBeforeCreatingState() {
        for invalidBuildIdentifier in ["", " bad", "bad/build"] {
            var ownerFactoryCalls = 0
            var runnerCalls = 0

            let result = HostAgentProcessEntryDriver.run(
                eligibility: HostAgentProcessEntryEligibility(
                    buildIdentifier: invalidBuildIdentifier,
                    signingChannel: .localDevelopment
                ),
                makeStateOwner: {
                    ownerFactoryCalls += 1
                    return try HostAgentProcessEntryStateOwner()
                },
                run: { _, _ in
                    runnerCalls += 1
                    return .stopped
                }
            )

            XCTAssertEqual(result, .internalFailure)
            XCTAssertEqual(ownerFactoryCalls, 0)
            XCTAssertEqual(runnerCalls, 0)
        }
    }

    func testProductWiringConsumesEligibilityButRealEntryRemainsClosed() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/HostAgentProcessProductEntry.swift"
            ),
            encoding: .utf8
        )
        let processSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/HostAgentProcess.swift"
            ),
            encoding: .utf8
        )
        let runtimeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/HostAgentProcessRuntime.swift"
            ),
            encoding: .utf8
        )
        let contextSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/ConnectionCatalog/HostAgentBootstrapContext.swift"
            ),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(productSource.contains("HostAgentProcessEntryDriver.run("))
        XCTAssertTrue(productSource.contains("eligibility: eligibility"))
        XCTAssertTrue(productSource.contains(
            "expectedAgentBuildID: eligibility.buildIdentifier"
        ))
        XCTAssertTrue(productSource.contains("stateOwner.eventState"))
        XCTAssertTrue(productSource.contains("stateOwner.snapshotState"))
        XCTAssertTrue(productSource.contains("stateOwner.mediaState"))
        XCTAssertFalse(productSource.contains("Bundle.main"))
        XCTAssertFalse(productSource.contains("ProcessInfo"))
        XCTAssertFalse(productSource.contains("getenv"))
        XCTAssertFalse(productSource.contains("exit("))

        XCTAssertTrue(processSource.contains(
            "expectedAgentBuildID: String"
        ))
        XCTAssertTrue(processSource.contains(
            "HostViewerConcurrencyEvidenceProcessOwner()"
        ))
        XCTAssertTrue(processSource.contains(
            ".configureHostAgent(\n"
                + "            expectedAgentBuildID: expectedAgentBuildID"
        ))
        XCTAssertTrue(processSource.contains(
            "_ = concurrencyEvidenceOwner.terminateAndWait()"
        ))
        XCTAssertTrue(processSource.contains(
            "recordInitialReadyConcurrencyEvidence("
        ))
        XCTAssertTrue(processSource.contains(
            "owner.recordHostAgentObservation("
        ))
        let evidenceConfigure = try XCTUnwrap(processSource.range(
            of: ".configureHostAgent("
        ))
        let processRun = try XCTUnwrap(processSource.range(
            of: "HostAgentProcessRunner.run("
        ))
        XCTAssertLessThan(evidenceConfigure.lowerBound, processRun.lowerBound)
        let listenerActivation = try XCTUnwrap(processSource.range(
            of: "lifetime.activateXPCListener()"
        ))
        let readyEvidence = try XCTUnwrap(processSource.range(
            of: "recordInitialReadyConcurrencyEvidence("
        ))
        XCTAssertLessThan(
            listenerActivation.lowerBound,
            readyEvidence.lowerBound
        )
        XCTAssertTrue(runtimeSource.contains(
            "HostAgentProcessEvidenceIdentity("
        ))
        XCTAssertTrue(runtimeSource.contains(
            "agentBootID: bootstrapContext.leaseRecord.agentBootID"
        ))
        XCTAssertTrue(runtimeSource.contains(
            "agentBuildID: bootstrapContext.leaseRecord.agentBuildID"
        ))
        XCTAssertTrue(runtimeSource.contains(
            "configRevision: bootstrapContext.leaseRecord.configRevision"
        ))
        XCTAssertTrue(runtimeSource.contains(
            "HostAgentBootstrapContext.prepare(\n"
                + "            expectedAgentBuildID: expectedAgentBuildID"
        ))
        XCTAssertTrue(contextSource.contains(
            "package static func prepare(\n"
                + "        expectedAgentBuildID: String"
        ))
        XCTAssertFalse(contextSource.contains(
            "package static func prepare(\n"
                + "        expectedAgentBuildID: String\n"
                + "    ) throws -> HostAgentBootstrapContext {\n"
                + "        let configuration = try "
                + "HostAgentBootstrapLaunchPreflight().prepare()"
        ))

        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
        XCTAssertFalse(appSource.contains("HostAgentProcessProductEntry.run("))
        XCTAssertFalse(appSource.contains(
            "HostAgentProcessEntryOrchestrator.resolve("
        ))
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
    }
}

private enum TestError: Error {
    case stateUnavailable
}
