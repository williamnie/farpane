@testable import CoreBridge
import XCTest

final class ViewerFileTransferRecursiveManifestAuthorityTests: XCTestCase {
    func testABIManifestPartsRevalidateAndProjectSemanticPayloads() throws {
        let file = CoreFileTransferListEntry(
            kind: .file,
            relativePath: "资料/report.txt",
            size: 42,
            modifiedTime: 10
        )
        let files = try XCTUnwrap(CoreFileTransferManifestEvent(
            sessionEpoch: 7,
            requestID: 11,
            status: .success,
            part: .files,
            entries: [file]
        ))
        guard case let .files(projectedFiles) = files.recursiveManifestPart else {
            return XCTFail("files event must project one semantic files part")
        }
        XCTAssertEqual(projectedFiles.first?.relativePath, "资料/report.txt")

        let directory = CoreFileTransferListEntry(
            kind: .directory,
            relativePath: "资料/empty",
            size: 0,
            modifiedTime: 0
        )
        let directories = try XCTUnwrap(CoreFileTransferManifestEvent(
            sessionEpoch: 7,
            requestID: 11,
            status: .success,
            part: .emptyDirectories,
            entries: [directory]
        ))
        XCTAssertEqual(
            directories.recursiveManifestPart,
            .emptyDirectories(["资料/empty"])
        )

        XCTAssertNil(CoreFileTransferManifestEvent(
            sessionEpoch: 7,
            requestID: 11,
            status: .success,
            part: .files,
            entries: [directory]
        ))
        XCTAssertNil(CoreFileTransferManifestEvent(
            sessionEpoch: 7,
            requestID: 11,
            status: .success,
            part: .emptyDirectories,
            entries: [file]
        ))
        XCTAssertNil(CoreFileTransferManifestEvent(
            sessionEpoch: 7,
            requestID: 11,
            status: .rejected,
            part: .files,
            entries: [file]
        ))
        XCTAssertNotNil(CoreFileTransferManifestEvent(
            sessionEpoch: 7,
            requestID: 11,
            status: .unavailable,
            part: .files,
            entries: []
        ))
    }

    func testCompletesOnlyAfterBothExactSessionPartsInEitherOrder() throws {
        let file = try makeFile(path: "资料/report.txt", size: 42)
        var authority = ViewerFileTransferRecursiveManifestAuthority()

        XCTAssertTrue(authority.begin(sessionEpoch: 7, requestID: 11))
        XCTAssertEqual(
            authority.observe(
                sessionEpoch: 7,
                requestID: 11,
                part: .emptyDirectories(["资料/empty"])
            ),
            .awaitingRemainingPart
        )
        let outcome = authority.observe(
            sessionEpoch: 7,
            requestID: 11,
            part: .files([file])
        )
        guard case let .completed(manifest) = outcome else {
            return XCTFail("both parts must complete one manifest")
        }
        XCTAssertEqual(manifest.files, [file])
        XCTAssertEqual(manifest.emptyDirectories, ["资料/empty"])
        XCTAssertEqual(manifest.totalBytes, 42)
        XCTAssertFalse(authority.isActive)
    }

    func testStaleDuplicateAndCrossPartCollisionsFailClosed() throws {
        let file = try makeFile(path: "Folder/report.txt", size: 1)
        var authority = ViewerFileTransferRecursiveManifestAuthority()
        XCTAssertTrue(authority.begin(sessionEpoch: 3, requestID: 4))

        XCTAssertNil(authority.observe(
            sessionEpoch: 2,
            requestID: 4,
            part: .files([file])
        ))
        XCTAssertNil(authority.observe(
            sessionEpoch: 3,
            requestID: 5,
            part: .files([file])
        ))
        XCTAssertEqual(
            authority.observe(sessionEpoch: 3, requestID: 4, part: .files([file])),
            .awaitingRemainingPart
        )
        XCTAssertEqual(
            authority.observe(sessionEpoch: 3, requestID: 4, part: .files([file])),
            .failed(.protocolViolation)
        )
        XCTAssertFalse(authority.isActive)

        XCTAssertTrue(authority.begin(sessionEpoch: 3, requestID: 5))
        XCTAssertEqual(
            authority.observe(sessionEpoch: 3, requestID: 5, part: .files([file])),
            .awaitingRemainingPart
        )
        XCTAssertEqual(
            authority.observe(
                sessionEpoch: 3,
                requestID: 5,
                part: .emptyDirectories(["folder"])
            ),
            .failed(.protocolViolation)
        )
        XCTAssertFalse(authority.isActive)
    }

    func testEachPartIsBoundedBeforeRetention() throws {
        let file = try makeFile(path: "one", size: 1)
        var authority = ViewerFileTransferRecursiveManifestAuthority()
        XCTAssertTrue(authority.begin(sessionEpoch: 1, requestID: 1))
        XCTAssertEqual(
            authority.observe(
                sessionEpoch: 1,
                requestID: 1,
                part: .files(Array(
                    repeating: file,
                    count: ViewerFileTransferManifest.maximumEntries + 1
                ))
            ),
            .failed(.protocolViolation)
        )

        let hugePath = String(
            repeating: "a",
            count: ViewerFileTransferManifest.maximumMetadataUTF8Bytes + 1
        )
        XCTAssertTrue(authority.begin(sessionEpoch: 1, requestID: 2))
        XCTAssertEqual(
            authority.observe(
                sessionEpoch: 1,
                requestID: 2,
                part: .emptyDirectories([hugePath])
            ),
            .failed(.protocolViolation)
        )
        XCTAssertFalse(authority.isActive)
    }

    func testStableFailureAndExactTeardownAreTerminal() {
        var authority = ViewerFileTransferRecursiveManifestAuthority()
        XCTAssertTrue(authority.begin(sessionEpoch: 8, requestID: 9))
        XCTAssertNil(authority.fail(
            sessionEpoch: 7,
            requestID: 9,
            failure: .unavailable
        ))
        XCTAssertNil(authority.fail(
            sessionEpoch: 8,
            requestID: 9,
            failure: .localIO
        ))
        XCTAssertEqual(
            authority.fail(sessionEpoch: 8, requestID: 9, failure: .unavailable),
            .failed(.unavailable)
        )
        XCTAssertFalse(authority.isActive)

        XCTAssertTrue(authority.begin(sessionEpoch: 8, requestID: 10))
        XCTAssertNil(authority.teardown(sessionEpoch: 7))
        XCTAssertEqual(authority.teardown(sessionEpoch: 8), 10)
        XCTAssertNil(authority.teardown(sessionEpoch: 8))
        XCTAssertFalse(authority.isActive)
    }

    private func makeFile(path: String, size: UInt64) throws
        -> ViewerFileTransferFile
    {
        try XCTUnwrap(ViewerFileTransferFile(
            relativePath: path,
            size: size,
            modifiedTime: 10
        ))
    }
}
