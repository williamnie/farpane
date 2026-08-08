import CoreBridge
import Foundation
import XCTest

final class HostAgentProcessStartupRunnerTests: XCTestCase {
    func testReturnsRuntimeWithoutInvokingFailureClassifier() throws {
        let runtime = TestStartupRuntime()
        var classifierCalls = 0

        let result = HostAgentProcessStartupRunner.start(
            startRuntime: { runtime },
            classifyError: { _ in
                classifierCalls += 1
                return HostAgentStartupFailure(kind: .internalFailure)
            }
        )

        guard case .success(let startedRuntime) = result else {
            return XCTFail("expected startup success")
        }
        XCTAssertTrue(startedRuntime === runtime)
        XCTAssertEqual(classifierCalls, 0)
    }

    func testClassifiesThrownErrorWithoutRetainingItsSensitiveDescription() {
        let secret = "server.example.invalid/private/path?token=do-not-copy"
        let thrownError = SecretBearingStartupError(description: secret)
        var classifiedError: Error?

        let result: Result<TestStartupRuntime, HostAgentStartupFailure> =
            HostAgentProcessStartupRunner.start(
                startRuntime: { throw thrownError },
                classifyError: { error in
                    classifiedError = error
                    return HostAgentStartupFailure(kind: .coreUnavailable)
                }
            )

        XCTAssertTrue(classifiedError as? SecretBearingStartupError === thrownError)
        guard case .failure(let failure) = result else {
            return XCTFail("expected startup failure")
        }
        XCTAssertEqual(failure.kind, .coreUnavailable)
        XCTAssertFalse(failure.diagnostic.contains(secret))
        XCTAssertFalse(String(describing: failure).contains(secret))
    }

    func testFailureKindsHaveFixedSysexitsAndSanitizedDiagnostics() {
        let expected: [(
            HostAgentStartupFailure.Kind,
            Int32,
            String
        )] = [
            (
                .configurationUnavailable,
                78,
                "FarPane HostAgent configuration is unavailable."
            ),
            (
                .runtimeOwnershipUnavailable,
                75,
                "FarPane HostAgent runtime ownership is unavailable."
            ),
            (
                .alreadyRunning,
                75,
                "FarPane HostAgent is already running."
            ),
            (
                .coreUnavailable,
                69,
                "FarPane HostAgent Core is unavailable or incompatible."
            ),
            (
                .runtimeStartupFailed,
                70,
                "FarPane HostAgent failed to start."
            ),
            (
                .internalFailure,
                70,
                "FarPane HostAgent encountered an internal startup error."
            ),
        ]

        for (kind, exitCode, diagnostic) in expected {
            let failure = HostAgentStartupFailure(kind: kind)
            XCTAssertEqual(failure.kind, kind)
            XCTAssertEqual(failure.exitCode, exitCode)
            XCTAssertEqual(failure.diagnostic, diagnostic)
            XCTAssertFalse(failure.diagnostic.contains("\n"))
            XCTAssertTrue(failure.diagnostic.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            })
        }
    }
}

private final class TestStartupRuntime {}

private final class SecretBearingStartupError: Error, CustomStringConvertible {
    let description: String

    init(description: String) {
        self.description = description
    }
}
