import Darwin
import Foundation
@testable import CoreBridge
import XCTest

final class ViewerFileTransferReceiveAdapterTests: XCTestCase {
    func testWritesCommitsZeroFilesAndEmptyDirectoriesInManifestOrder() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 7,
            directoryURL: directory,
            leaseToken: 91
        ))
        let request = try makeRequest(
            owner: owner,
            transferID: 61,
            files: [
                ("zero.txt", 0, 10),
                ("nested/data.bin", 5, 20),
                ("tail.txt", 0, 30),
            ],
            emptyDirectories: ["empty/leaf"]
        )
        let recorder = EventRecorder()
        let adapter = ViewerFileTransferReceiveAdapter()

        XCTAssertTrue(adapter.begin(request, destinationOwner: owner) {
            recorder.append($0)
        })
        XCTAssertEqual(adapter.receive(try block(
            epoch: 7,
            transferID: 61,
            fileNumber: 1,
            payload: "hello"
        )), .accepted)
        XCTAssertEqual(
            adapter.observe(try completedEvent(request)),
            .forward
        )
        XCTAssertEqual(recorder.events, [
            .fileCommitted(fileNumber: 0),
            .fileCommitted(fileNumber: 1),
            .fileCommitted(fileNumber: 2),
            .completed,
        ])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("zero.txt")), Data())
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("nested/data.bin")),
            Data("hello".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("tail.txt")), Data())
        var status = stat()
        XCTAssertEqual(Darwin.lstat(directory.appendingPathComponent("empty/leaf").path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o700))
        XCTAssertEqual(adapter.activeCount, 0)
    }

    func testRejectsStaleOutOfOrderAndOversizeBlocksAndCleansStaging() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 8,
            directoryURL: directory,
            leaseToken: 92
        ))
        let request = try makeRequest(
            owner: owner,
            transferID: 62,
            files: [("one.bin", 4, 10), ("two.bin", 1, 20)]
        )
        let recorder = EventRecorder()
        let adapter = ViewerFileTransferReceiveAdapter()
        XCTAssertTrue(adapter.begin(request, destinationOwner: owner) { recorder.append($0) })

        XCTAssertEqual(adapter.receive(try block(
            epoch: 9,
            transferID: 62,
            fileNumber: 0,
            payload: "ab"
        )), .cancelRequired)
        XCTAssertEqual(recorder.events, [.failed(.protocolViolation)])
        XCTAssertEqual(adapter.activeCount, 0)

        let secondRecorder = EventRecorder()
        XCTAssertTrue(adapter.begin(request, destinationOwner: owner) { secondRecorder.append($0) })
        XCTAssertEqual(adapter.receive(try block(
            epoch: 8,
            transferID: 62,
            fileNumber: 1,
            payload: "x"
        )), .cancelRequired)
        XCTAssertEqual(secondRecorder.events, [.failed(.protocolViolation)])

        let thirdRecorder = EventRecorder()
        XCTAssertTrue(adapter.begin(request, destinationOwner: owner) { thirdRecorder.append($0) })
        XCTAssertEqual(adapter.receive(try block(
            epoch: 8,
            transferID: 62,
            fileNumber: 0,
            payload: "abcde"
        )), .cancelRequired)
        XCTAssertEqual(thirdRecorder.events, [.failed(.protocolViolation)])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("one.bin.farpane-part").path
        ))
    }

    func testTerminalFailureCancellationRollbackAndTeardownAreExact() throws {
        let firstDirectory = try makePrivateDirectory()
        let secondDirectory = try makePrivateDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let firstOwner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 10,
            directoryURL: firstDirectory,
            leaseToken: 100
        ))
        let secondOwner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 11,
            directoryURL: secondDirectory,
            leaseToken: 101
        ))
        let first = try makeRequest(owner: firstOwner, transferID: 70, files: [("a", 4, 1)])
        let second = try makeRequest(owner: secondOwner, transferID: 71, files: [("b", 4, 1)])
        let firstRecorder = EventRecorder()
        let secondRecorder = EventRecorder()
        let adapter = ViewerFileTransferReceiveAdapter()
        XCTAssertTrue(adapter.begin(first, destinationOwner: firstOwner) { firstRecorder.append($0) })
        XCTAssertTrue(adapter.begin(second, destinationOwner: secondOwner) { secondRecorder.append($0) })
        XCTAssertEqual(adapter.receive(try block(
            epoch: 10,
            transferID: 70,
            fileNumber: 0,
            payload: "ab"
        )), .accepted)
        XCTAssertFalse(adapter.rollback(sessionEpoch: 9, transferID: 70))
        XCTAssertTrue(adapter.rollback(sessionEpoch: 10, transferID: 70))
        XCTAssertEqual(firstRecorder.events, [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: firstDirectory.appendingPathComponent("a.farpane-part").path
        ))

        XCTAssertEqual(adapter.teardown(sessionEpoch: 10), [])
        XCTAssertEqual(adapter.teardown(sessionEpoch: 11), [71])
        XCTAssertEqual(secondRecorder.events, [.failed(.connectionClosed)])
        XCTAssertEqual(adapter.activeCount, 0)
    }

    func testRemoteTerminalAndPrematureCompletionDoNotMasqueradeAsLocalCommit() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 12,
            directoryURL: directory,
            leaseToken: 102
        ))
        let request = try makeRequest(owner: owner, transferID: 72, files: [("a", 4, 1)])
        let recorder = EventRecorder()
        let adapter = ViewerFileTransferReceiveAdapter()
        XCTAssertTrue(adapter.begin(request, destinationOwner: owner) { recorder.append($0) })

        XCTAssertEqual(adapter.observe(try completedEvent(request)), .suppress)
        XCTAssertEqual(recorder.events, [.failed(.protocolViolation)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a").path))

        let remoteRecorder = EventRecorder()
        XCTAssertTrue(adapter.begin(request, destinationOwner: owner) { remoteRecorder.append($0) })
        XCTAssertEqual(adapter.observe(try failedEvent(request, failure: .unavailable)), .forward)
        XCTAssertEqual(remoteRecorder.events, [.failed(.remote(.unavailable))])
    }

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ViewerFileTransferReceiveEvent] = []

        var events: [ViewerFileTransferReceiveEvent] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func append(_ event: ViewerFileTransferReceiveEvent) {
            lock.lock(); storage.append(event); lock.unlock()
        }
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(Darwin.chmod(directory.path, 0o700), 0)
        return directory
    }

    private func makeRequest(
        owner: ViewerFileTransferDestinationOwner,
        transferID: Int32,
        files: [(String, UInt64, Int64)],
        emptyDirectories: [String] = []
    ) throws -> ViewerFileTransferDownloadRequest {
        let lease = try XCTUnwrap(owner.lease)
        let entries = try files.map { path, size, modifiedTime in
            try XCTUnwrap(ViewerFileTransferFile(
                relativePath: path,
                size: size,
                modifiedTime: modifiedTime
            ))
        }
        let manifest = try XCTUnwrap(ViewerFileTransferManifest(
            files: entries,
            emptyDirectories: emptyDirectories
        ))
        return try XCTUnwrap(ViewerFileTransferDownloadRequest(
            sessionEpoch: lease.sessionEpoch,
            transferID: transferID,
            destination: lease,
            manifest: manifest
        ))
    }

    private func block(
        epoch: UInt64,
        transferID: Int32,
        fileNumber: UInt32,
        payload: String
    ) throws -> CoreFileTransferReceiveBlock {
        try XCTUnwrap(CoreFileTransferReceiveBlock(
            sessionEpoch: epoch,
            transferID: transferID,
            fileNumber: fileNumber,
            payload: Data(payload.utf8)
        ))
    }

    private func completedEvent(
        _ request: ViewerFileTransferDownloadRequest
    ) throws -> CoreFileTransferEvent {
        try XCTUnwrap(CoreFileTransferEvent(
            sessionEpoch: request.sessionEpoch,
            transferID: request.transferID,
            sequence: 1,
            kind: .completed,
            failure: .none,
            currentFileNumber: nil,
            filesCompleted: UInt32(request.manifest.files.count),
            totalFiles: UInt32(request.manifest.files.count),
            bytesCompleted: request.manifest.totalBytes,
            totalBytes: request.manifest.totalBytes,
            bytesPerSecond: 0
        ))
    }

    private func failedEvent(
        _ request: ViewerFileTransferDownloadRequest,
        failure: CoreFileTransferFailure
    ) throws -> CoreFileTransferEvent {
        try XCTUnwrap(CoreFileTransferEvent(
            sessionEpoch: request.sessionEpoch,
            transferID: request.transferID,
            sequence: 1,
            kind: .failed,
            failure: failure,
            currentFileNumber: nil,
            filesCompleted: 0,
            totalFiles: UInt32(request.manifest.files.count),
            bytesCompleted: 0,
            totalBytes: request.manifest.totalBytes,
            bytesPerSecond: 0
        ))
    }
}
