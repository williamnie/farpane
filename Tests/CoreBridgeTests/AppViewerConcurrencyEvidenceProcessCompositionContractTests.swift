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
