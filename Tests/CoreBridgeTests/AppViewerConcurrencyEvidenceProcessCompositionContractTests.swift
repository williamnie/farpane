import Foundation
import XCTest

final class AppViewerConcurrencyEvidenceProcessCompositionContractTests:
    XCTestCase
{
    func testApplicationOwnsOneBestEffortLifecycleEvidenceOwner() throws {
        let app = try repositorySource(
            "Sources/RustDeskNative/RustDeskNativeApp.swift"
        )

        XCTAssertEqual(
            app.components(
                separatedBy: "HostViewerConcurrencyEvidenceProcessOwner()"
            ).count - 1,
            1
        )
        XCTAssertTrue(app.contains(
            "_ = delegate.hostViewerConcurrencyEvidenceOwner\n"
                + "            .configureApplication()"
        ))
        XCTAssertFalse(app.contains(
            "guard delegate.hostViewerConcurrencyEvidenceOwner"
        ))
        XCTAssertFalse(app.contains(
            "try delegate.hostViewerConcurrencyEvidenceOwner"
        ))

        try assertOrder(
            in: app,
            "exit(HostAgentProcessBootstrap.run())",
            "let delegate = AppDelegate()"
        )
        try assertOrder(
            in: app,
            "let delegate = AppDelegate()",
            ".configureApplication()"
        )
        try assertOrder(
            in: app,
            ".configureApplication()",
            "application.delegate = delegate"
        )
        try assertOrder(
            in: app,
            "application.delegate = delegate",
            "application.run()"
        )
    }

    func testAllOwnedApplicationExitPathsCloseEvidenceBestEffort() throws {
        let app = try repositorySource(
            "Sources/RustDeskNative/RustDeskNativeApp.swift"
        )

        XCTAssertEqual(
            app.components(separatedBy: "terminateAndWait()").count - 1,
            2
        )
        XCTAssertTrue(app.contains(
            "_ = hostViewerConcurrencyEvidenceOwner.terminateAndWait()"
        ))
        try assertOrder(
            in: app,
            "fputs(\"RustDeskNative startup failed:",
            "_ = hostViewerConcurrencyEvidenceOwner.terminateAndWait()"
        )
        try assertOrder(
            in: app,
            "_ = hostViewerConcurrencyEvidenceOwner.terminateAndWait()",
            "exit(2)"
        )

        let termination = try XCTUnwrap(app.range(
            of: "func applicationWillTerminate(_ notification: Notification)"
        ))
        let finish = try XCTUnwrap(
            app.range(of: "        finish()", range: termination.lowerBound..<app.endIndex)
        )
        let evidence = try XCTUnwrap(app.range(
            of: "_ = hostViewerConcurrencyEvidenceOwner.terminateAndWait()",
            range: finish.upperBound..<app.endIndex
        ))
        XCTAssertLessThan(finish.lowerBound, evidence.lowerBound)
    }

    func testViewerLifecycleUsesExactCoreAndAppTeardownEdges() throws {
        let app = try repositorySource(
            "Sources/RustDeskNative/RustDeskNativeApp.swift"
        )

        XCTAssertTrue(app.contains(
            "hostViewerConcurrencyEvidenceOwner.beginViewerSession()"
        ))
        XCTAssertTrue(app.contains(
            "if event.state == .streaming {"
        ))
        XCTAssertTrue(app.contains(
            "hostViewerConcurrencyEvidenceOwner.observeViewerStreaming(\n"
                + "                    sessionEpoch: evidenceSessionEpoch"
        ))
        XCTAssertTrue(app.contains(
            "hostViewerConcurrencyEvidenceOwner.observeViewerTerminal(\n"
                + "                sessionEpoch: evidenceSessionEpoch"
        ))
        XCTAssertTrue(app.contains(
            "private func stopViewerLifecycleEvidence()"
        ))
        XCTAssertTrue(app.contains(
            "reaffirmHostAgentApplicationConcurrencyEvidence()"
        ))
        XCTAssertFalse(app.contains(
            "peerID: configuration.peerID"
        ))

        let home = try XCTUnwrap(app.range(
            of: "private func showHomeUI(error: String = \"\")"
        ))
        let homeStop = try XCTUnwrap(app.range(
            of: "stopViewerLifecycleEvidence()",
            range: home.lowerBound..<app.endIndex
        ))
        let homeDisconnect = try XCTUnwrap(app.range(
            of: "coreClient?.disconnect()",
            range: homeStop.upperBound..<app.endIndex
        ))
        XCTAssertLessThan(homeStop.lowerBound, homeDisconnect.lowerBound)
        let homeReaffirm = try XCTUnwrap(app.range(
            of: "reaffirmHostAgentApplicationConcurrencyEvidence()",
            range: homeStop.upperBound..<homeDisconnect.lowerBound
        ))
        XCTAssertLessThan(homeStop.lowerBound, homeReaffirm.lowerBound)

        let coreState = try XCTUnwrap(app.range(
            of: "private func handleViewerCoreState("
        ))
        let viewerStreaming = try XCTUnwrap(app.range(
            of: "hostViewerConcurrencyEvidenceOwner.observeViewerStreaming(",
            range: coreState.lowerBound..<app.endIndex
        ))
        let streamingReaffirm = try XCTUnwrap(app.range(
            of: "reaffirmHostAgentApplicationConcurrencyEvidence()",
            range: viewerStreaming.upperBound..<app.endIndex
        ))
        XCTAssertLessThan(
            viewerStreaming.lowerBound,
            streamingReaffirm.lowerBound
        )

        let finish = try XCTUnwrap(app.range(of: "private func finish()"))
        let finishStop = try XCTUnwrap(app.range(
            of: "stopViewerLifecycleEvidence()",
            range: finish.lowerBound..<app.endIndex
        ))
        let finishDisconnect = try XCTUnwrap(app.range(
            of: "coreClient?.disconnect()",
            range: finishStop.upperBound..<app.endIndex
        ))
        XCTAssertLessThan(finishStop.lowerBound, finishDisconnect.lowerBound)
    }

    func testViewerAutomaticRecoveryReplacesCoreWithinSameEvidenceEpoch()
        throws
    {
        let app = try repositorySource(
            "Sources/RustDeskNative/RustDeskNativeApp.swift"
        )

        XCTAssertTrue(app.contains("ViewerAutomaticRecoveryOwner.makeProduct("))
        XCTAssertTrue(app.contains("attemptViewerAutomaticRecovery("))
        XCTAssertTrue(app.contains(
            "credentialStore.read(deviceID: deviceID)"
        ))
        XCTAssertTrue(app.contains(
            "evidenceSessionEpoch: evidenceSessionEpoch"
        ))
        XCTAssertTrue(app.contains(
            "guard coreGeneration == viewerCoreGeneration else { return }"
        ))
        XCTAssertTrue(app.contains(
            "previousClient?.disconnect()"
        ))
        XCTAssertTrue(app.contains(
            "connectionStateText(event)"
        ))
        XCTAssertFalse(app.contains("viewerRecoveryPassword"))

        let home = try XCTUnwrap(app.range(
            of: "private func showHomeUI(error: String = \"\")"
        ))
        let stopRecovery = try XCTUnwrap(app.range(
            of: "stopViewerAutomaticRecovery()",
            range: home.lowerBound..<app.endIndex
        ))
        let stopEvidence = try XCTUnwrap(app.range(
            of: "stopViewerLifecycleEvidence()",
            range: stopRecovery.upperBound..<app.endIndex
        ))
        XCTAssertLessThan(stopRecovery.lowerBound, stopEvidence.lowerBound)
    }

    func testApplicationHostObservationUsesCoherentProjectionAndXPCIdentity()
        throws
    {
        let app = try repositorySource(
            "Sources/RustDeskNative/RustDeskNativeApp.swift"
        )

        XCTAssertEqual(
            app.components(
                separatedBy:
                    "HostAgentApplicationConcurrencyObservationState()"
            ).count - 1,
            1
        )
        XCTAssertTrue(app.contains(
            "defer { observeHostAgentApplicationConcurrencyEvidence() }"
        ))
        XCTAssertTrue(app.contains(
            "coherentConfigRevision: configRevision"
        ))
        XCTAssertTrue(app.contains(
            ".observeApplicationHostAgentRuntimeState("
        ))
        XCTAssertTrue(app.contains(
            "agentProcessID:"
        ))
        XCTAssertTrue(app.contains(
            "observation.peerIdentity.agentProcessID"
        ))
        XCTAssertTrue(app.contains(
            ".agentProcessStartIdentitySHA256"
        ))
        XCTAssertTrue(app.contains(
            "sourceToken: activationView.generation"
        ))
        XCTAssertFalse(app.contains("getpid()"))
        XCTAssertFalse(app.contains("PROC_PIDTBSDINFO"))
        try assertOrder(
            in: app,
            "refreshHostAgentRuntimeConfigurationCoherence()",
            ".observeApplicationHostAgentRuntimeState("
        )
    }

    private func repositorySource(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func assertOrder(
        in source: String,
        _ earlier: String,
        _ later: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let earlierRange = try XCTUnwrap(
            source.range(of: earlier),
            "missing earlier source marker",
            file: file,
            line: line
        )
        let laterRange = try XCTUnwrap(
            source.range(of: later),
            "missing later source marker",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            earlierRange.lowerBound,
            laterRange.lowerBound,
            file: file,
            line: line
        )
    }
}
