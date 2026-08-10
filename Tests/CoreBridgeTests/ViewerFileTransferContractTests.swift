@testable import CoreBridge
import XCTest

final class ViewerFileTransferContractTests: XCTestCase {
    func testRemoteRootListRevalidatesOwnedMetadataAndStableFailures() throws {
        let directory = CoreFileTransferListEntry(
            kind: .directory,
            relativePath: "资料",
            size: 0,
            modifiedTime: 10
        )
        let file = CoreFileTransferListEntry(
            kind: .file,
            relativePath: "report.txt",
            size: 42,
            modifiedTime: 20
        )
        let success = try XCTUnwrap(CoreFileTransferListEvent(
            sessionEpoch: 7,
            requestID: 3,
            status: .success,
            entries: [directory, file]
        ))
        XCTAssertEqual(success.entries, [directory, file])
        XCTAssertNotNil(CoreFileTransferListEvent(
            sessionEpoch: 7,
            requestID: 4,
            status: .success,
            entries: []
        ))
        XCTAssertNotNil(CoreFileTransferListEvent(
            sessionEpoch: 7,
            requestID: 5,
            status: .unavailable,
            entries: []
        ))
        XCTAssertNil(CoreFileTransferListEvent(
            sessionEpoch: 7,
            requestID: 5,
            status: .rejected,
            entries: [file]
        ))

        for invalidPath in ["nested/file", "windows\\path", "bad\nname", "e\u{301}"] {
            XCTAssertNil(CoreFileTransferListEvent(
                sessionEpoch: 7,
                requestID: 6,
                status: .success,
                entries: [CoreFileTransferListEntry(
                    kind: .file,
                    relativePath: invalidPath,
                    size: 1,
                    modifiedTime: 0
                )]
            ), invalidPath)
        }
        XCTAssertNil(CoreFileTransferListEvent(
            sessionEpoch: 7,
            requestID: 7,
            status: .success,
            entries: [CoreFileTransferListEntry(
                kind: .directory,
                relativePath: "nonempty",
                size: 1,
                modifiedTime: 0
            )]
        ))
        XCTAssertNil(CoreFileTransferListEvent(
            sessionEpoch: 7,
            requestID: 8,
            status: .success,
            entries: [
                CoreFileTransferListEntry(kind: .file, relativePath: "Alias", size: 1, modifiedTime: 0),
                CoreFileTransferListEntry(kind: .file, relativePath: "alias", size: 1, modifiedTime: 0),
            ]
        ))
    }

    func testManifestAcceptsOnlyBoundedCanonicalNonCollidingPaths() throws {
        let first = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "reports/one.txt",
            size: 4,
            modifiedTime: 10
        ))
        let second = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "two.txt",
            size: 6,
            modifiedTime: 20
        ))
        let manifest = try XCTUnwrap(ViewerFileTransferManifest(
            files: [first, second],
            emptyDirectories: ["empty"]
        ))

        XCTAssertEqual(manifest.totalBytes, 10)
        XCTAssertEqual(manifest.metadataUTF8Bytes, 27)
        for path in ["", "/absolute", "a/", "a//b", "a/./b", "a/../b", "bad\0name"] {
            XCTAssertFalse(ViewerFileTransferManifest.accepts(relativePath: path), path)
        }
        XCTAssertFalse(ViewerFileTransferManifest.accepts(relativePath: "private.farpane-part"))
        XCTAssertFalse(ViewerFileTransferManifest.accepts(relativePath: "private.FARPANE-PART"))
        XCTAssertFalse(ViewerFileTransferManifest.accepts(relativePath: "e\u{301}"))
        XCTAssertNil(ViewerFileTransferManifest(files: [first], emptyDirectories: [first.relativePath]))
        XCTAssertNil(ViewerFileTransferManifest(files: [first], emptyDirectories: ["reports"]))

        let caseAlias = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "REPORTS/ONE.TXT",
            size: 1,
            modifiedTime: 0
        ))
        XCTAssertNil(ViewerFileTransferManifest(
            files: [first, caseAlias],
            emptyDirectories: []
        ))
    }

    func testManifestRejectsEntryMetadataAndByteOverflow() throws {
        let file = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "one",
            size: 1,
            modifiedTime: 0
        ))
        XCTAssertNil(ViewerFileTransferManifest(
            files: Array(repeating: file, count: ViewerFileTransferManifest.maximumEntries + 1),
            emptyDirectories: []
        ))
        let huge = String(repeating: "a", count: ViewerFileTransferManifest.maximumMetadataUTF8Bytes + 1)
        XCTAssertNil(ViewerFileTransferFile(relativePath: huge, size: 1, modifiedTime: 0))

        let max = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "max",
            size: UInt64.max,
            modifiedTime: 0
        ))
        XCTAssertNil(ViewerFileTransferManifest(files: [max, file], emptyDirectories: []))
    }

    func testRequestRequiresSessionBoundOpaqueDestinationAndPositiveID() throws {
        let manifest = try makeManifest()
        let destination = try XCTUnwrap(ViewerFileTransferDestinationLease(token: 9, sessionEpoch: 7))
        XCTAssertNotNil(ViewerFileTransferDownloadRequest(
            sessionEpoch: 7,
            transferID: 3,
            destination: destination,
            manifest: manifest
        ))
        XCTAssertNil(ViewerFileTransferDestinationLease(token: 0, sessionEpoch: 7))
        XCTAssertNil(ViewerFileTransferDownloadRequest(
            sessionEpoch: 8,
            transferID: 3,
            destination: destination,
            manifest: manifest
        ))
        XCTAssertNil(ViewerFileTransferDownloadRequest(
            sessionEpoch: 7,
            transferID: 0,
            destination: destination,
            manifest: manifest
        ))
    }

    func testDownloadStartProjectsOnlyExactManifestAndScalarTotals() throws {
        let request = try makeRequest(epoch: 7, identifier: 3)
        let start = try XCTUnwrap(CoreFileTransferDownloadStart(
            request: request,
            manifestRequestID: 51
        ))

        XCTAssertEqual(start.sessionEpoch, 7)
        XCTAssertEqual(start.manifestRequestID, 51)
        XCTAssertEqual(start.transferID, 3)
        XCTAssertEqual(start.totalFiles, 1)
        XCTAssertEqual(start.totalBytes, 4)
        XCTAssertNil(CoreFileTransferDownloadStart(
            request: request,
            manifestRequestID: 0
        ))
    }

    func testCoreProgressEventValidatesAndProjectsStableViewerUpdate() throws {
        let event = try XCTUnwrap(CoreFileTransferEvent(
            sessionEpoch: 7,
            transferID: 3,
            sequence: 2,
            kind: .progress,
            failure: .none,
            currentFileNumber: 0,
            filesCompleted: 0,
            totalFiles: 1,
            bytesCompleted: 2,
            totalBytes: 4,
            bytesPerSecond: 5
        ))
        XCTAssertEqual(event.viewerProgressUpdate, ViewerFileTransferProgressUpdate(
            sessionEpoch: 7,
            transferID: 3,
            sequence: 2,
            phase: .transferring,
            currentFileNumber: 0,
            filesCompleted: 0,
            bytesCompleted: 2,
            bytesPerSecond: 5
        ))

        let failed = try XCTUnwrap(CoreFileTransferEvent(
            sessionEpoch: 7,
            transferID: 3,
            sequence: 3,
            kind: .failed,
            failure: .unavailable,
            currentFileNumber: nil,
            filesCompleted: 0,
            totalFiles: 1,
            bytesCompleted: 2,
            totalBytes: 4,
            bytesPerSecond: 0
        ))
        XCTAssertEqual(failed.viewerProgressUpdate?.phase, .failed(.unavailable))
    }

    func testCoreProgressEventRejectsMalformedTerminalAndBounds() {
        XCTAssertNil(CoreFileTransferEvent(
            sessionEpoch: 7,
            transferID: 3,
            sequence: 0,
            kind: .progress,
            failure: .none,
            currentFileNumber: 0,
            filesCompleted: 0,
            totalFiles: 1,
            bytesCompleted: 0,
            totalBytes: 4,
            bytesPerSecond: 0
        ))
        XCTAssertNil(CoreFileTransferEvent(
            sessionEpoch: 7,
            transferID: 3,
            sequence: 1,
            kind: .progress,
            failure: .none,
            currentFileNumber: 1,
            filesCompleted: 0,
            totalFiles: 1,
            bytesCompleted: 0,
            totalBytes: 4,
            bytesPerSecond: 0
        ))
        XCTAssertNil(CoreFileTransferEvent(
            sessionEpoch: 7,
            transferID: 3,
            sequence: 1,
            kind: .completed,
            failure: .none,
            currentFileNumber: nil,
            filesCompleted: 0,
            totalFiles: 1,
            bytesCompleted: 4,
            totalBytes: 4,
            bytesPerSecond: 0
        ))
        XCTAssertNil(CoreFileTransferEvent(
            sessionEpoch: 7,
            transferID: 3,
            sequence: 1,
            kind: .failed,
            failure: .none,
            currentFileNumber: nil,
            filesCompleted: 0,
            totalFiles: 1,
            bytesCompleted: 0,
            totalBytes: 4,
            bytesPerSecond: 0
        ))
        XCTAssertNil(CoreFileTransferEvent(
            sessionEpoch: 7,
            transferID: 3,
            sequence: 1,
            kind: .cancelled,
            failure: .none,
            currentFileNumber: 0,
            filesCompleted: 0,
            totalFiles: 1,
            bytesCompleted: 0,
            totalBytes: 4,
            bytesPerSecond: 0
        ))
    }

    func testProgressIsMonotonicBoundedAndTerminal() throws {
        var authority = ViewerFileTransferProgressAuthority()
        let request = try makeRequest(epoch: 7, identifier: 3)
        XCTAssertEqual(authority.begin(request)?.phase, .queued)

        let moving = update(
            epoch: 7,
            identifier: 3,
            sequence: 1,
            phase: .transferring,
            currentFile: 0,
            filesCompleted: 0,
            bytesCompleted: 2,
            speed: 5
        )
        XCTAssertEqual(authority.observe(moving)?.bytesCompleted, 2)
        XCTAssertNil(authority.observe(moving))
        XCTAssertNil(authority.observe(update(
            epoch: 7,
            identifier: 3,
            sequence: 2,
            phase: .transferring,
            currentFile: 0,
            filesCompleted: 0,
            bytesCompleted: 1,
            speed: 5
        )))
        XCTAssertNil(authority.observe(update(
            epoch: 7,
            identifier: 3,
            sequence: 2,
            phase: .completed,
            currentFile: nil,
            filesCompleted: 0,
            bytesCompleted: 4,
            speed: 0
        )))

        let completed = authority.observe(update(
            epoch: 7,
            identifier: 3,
            sequence: 3,
            phase: .completed,
            currentFile: nil,
            filesCompleted: 1,
            bytesCompleted: 4,
            speed: 0
        ))
        XCTAssertEqual(completed?.phase, .completed)
        XCTAssertEqual(authority.activeCount, 0)
        XCTAssertNil(authority.observe(update(
            epoch: 7,
            identifier: 3,
            sequence: 4,
            phase: .failed(.protocolViolation),
            currentFile: nil,
            filesCompleted: 1,
            bytesCompleted: 4,
            speed: 0
        )))
    }

    func testConflictCancellationStaleSessionAndTeardownFailClosed() throws {
        var authority = ViewerFileTransferProgressAuthority()
        XCTAssertNotNil(authority.begin(try makeRequest(epoch: 4, identifier: 1)))
        XCTAssertNotNil(authority.begin(try makeRequest(epoch: 4, identifier: 2)))
        XCTAssertNil(authority.observe(update(
            epoch: 4,
            identifier: 1,
            sequence: 1,
            phase: .waitingForConflict,
            currentFile: nil,
            filesCompleted: 0,
            bytesCompleted: 0,
            speed: 0
        )))
        XCTAssertEqual(authority.observe(update(
            epoch: 4,
            identifier: 1,
            sequence: 1,
            phase: .waitingForConflict,
            currentFile: 0,
            filesCompleted: 0,
            bytesCompleted: 0,
            speed: 0
        ))?.phase, .waitingForConflict)
        XCTAssertNil(authority.requestCancellation(sessionEpoch: 5, transferID: 1))
        XCTAssertEqual(
            authority.requestCancellation(sessionEpoch: 4, transferID: 1)?.phase,
            .cancelling
        )
        XCTAssertNil(authority.observe(update(
            epoch: 4,
            identifier: 1,
            sequence: 2,
            phase: .transferring,
            currentFile: 0,
            filesCompleted: 0,
            bytesCompleted: 1,
            speed: 1
        )))
        XCTAssertEqual(authority.observe(update(
            epoch: 4,
            identifier: 1,
            sequence: 2,
            phase: .cancelled,
            currentFile: nil,
            filesCompleted: 0,
            bytesCompleted: 0,
            speed: 0
        ))?.phase, .cancelled)
        XCTAssertEqual(authority.teardown(sessionEpoch: 4), [2])
        XCTAssertEqual(authority.activeCount, 0)
    }

    func testConcurrencyLimitAndDuplicateIdentifiersAreBounded() throws {
        var authority = ViewerFileTransferProgressAuthority()
        for identifier in 1...ViewerFileTransferProgressAuthority.maximumConcurrentTransfers {
            XCTAssertNotNil(authority.begin(try makeRequest(
                epoch: 1,
                identifier: Int32(identifier)
            )))
        }
        XCTAssertNil(authority.begin(try makeRequest(epoch: 1, identifier: 1)))
        XCTAssertNil(authority.begin(try makeRequest(epoch: 1, identifier: 99)))
    }

    private func makeManifest() throws -> ViewerFileTransferManifest {
        let file = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "one.txt",
            size: 4,
            modifiedTime: 10
        ))
        return try XCTUnwrap(ViewerFileTransferManifest(files: [file], emptyDirectories: []))
    }

    private func makeRequest(
        epoch: UInt64,
        identifier: Int32
    ) throws -> ViewerFileTransferDownloadRequest {
        let destination = try XCTUnwrap(ViewerFileTransferDestinationLease(
            token: UInt64(identifier) + 100,
            sessionEpoch: epoch
        ))
        return try XCTUnwrap(ViewerFileTransferDownloadRequest(
            sessionEpoch: epoch,
            transferID: identifier,
            destination: destination,
            manifest: makeManifest()
        ))
    }

    private func update(
        epoch: UInt64,
        identifier: Int32,
        sequence: UInt64,
        phase: ViewerFileTransferProgressPhase,
        currentFile: Int?,
        filesCompleted: Int,
        bytesCompleted: UInt64,
        speed: Double
    ) -> ViewerFileTransferProgressUpdate {
        ViewerFileTransferProgressUpdate(
            sessionEpoch: epoch,
            transferID: identifier,
            sequence: sequence,
            phase: phase,
            currentFileNumber: currentFile,
            filesCompleted: filesCompleted,
            bytesCompleted: bytesCompleted,
            bytesPerSecond: speed
        )
    }
}
