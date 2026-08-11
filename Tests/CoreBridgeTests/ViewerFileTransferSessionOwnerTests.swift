import Foundation
@testable import CoreBridge
import XCTest

final class ViewerFileTransferSessionOwnerTests: XCTestCase {
    func testRequestsManifestStartsDownloadAndRequiresLocalCompletionProof() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try makeDestination(epoch: 7, directory: directory, token: 91)
        let core = ViewerFileTransferSessionCoreRecorder()
        let events = ViewerFileTransferSessionEventRecorder()
        let owner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 7,
            core: core,
            onEvent: events.handler
        ))

        XCTAssertTrue(owner.beginDownload(
            manifestRequestID: 51,
            transferID: 61,
            destinationOwner: destination
        ))
        XCTAssertEqual(core.manifestRequests, [.init(epoch: 7, requestID: 51)])
        XCTAssertEqual(events.values, [
            .manifestRequested(sessionEpoch: 7, requestID: 51, transferID: 61),
        ])

        XCTAssertTrue(owner.observeManifest(try manifestEvent(
            epoch: 7,
            requestID: 51,
            part: .files,
            entries: [fileEntry(path: "zero.txt", size: 0, modifiedTime: 10)]
        )))
        XCTAssertTrue(owner.observeManifest(try manifestEvent(
            epoch: 7,
            requestID: 51,
            part: .emptyDirectories,
            entries: []
        )))
        XCTAssertEqual(core.starts.count, 1)
        XCTAssertEqual(core.starts.first?.epoch, 7)
        XCTAssertEqual(core.starts.first?.manifestRequestID, 51)
        XCTAssertEqual(core.starts.first?.transferID, 61)
        XCTAssertEqual(core.starts.first?.destination, destination.lease)
        XCTAssertEqual(events.values.last, .progress(try queuedSnapshot(
            epoch: 7,
            transferID: 61,
            totalFiles: 1,
            totalBytes: 0
        )))

        core.emitReceive(.fileCommitted(fileNumber: 0), transferID: 61)
        core.emitReceive(.completed, transferID: 61)
        XCTAssertTrue(owner.observeCore(try terminalEvent(
            epoch: 7,
            transferID: 61,
            kind: .completed,
            failure: .none,
            totalFiles: 1,
            totalBytes: 0
        )))

        XCTAssertEqual(events.values.suffix(3), [
            .fileCommitted(sessionEpoch: 7, transferID: 61, fileNumber: 0),
            .progress(try terminalSnapshot(
                epoch: 7,
                transferID: 61,
                phase: .completed,
                totalFiles: 1,
                totalBytes: 0
            )),
            .finished(
                sessionEpoch: 7,
                transferID: 61,
                outcome: .completed
            ),
        ])
        XCTAssertNil(destination.lease)
        XCTAssertEqual(owner.snapshot().activeTransferIDs, [])
    }

    func testSerializesManifestRequestsWhileAllowingActiveDownload() throws {
        let firstDirectory = try makePrivateDirectory()
        let secondDirectory = try makePrivateDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let first = try makeDestination(epoch: 8, directory: firstDirectory, token: 101)
        let second = try makeDestination(epoch: 8, directory: secondDirectory, token: 102)
        let core = ViewerFileTransferSessionCoreRecorder()
        let owner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 8,
            core: core,
            onEvent: { _ in }
        ))

        XCTAssertTrue(owner.beginDownload(
            manifestRequestID: 52,
            transferID: 62,
            destinationOwner: first
        ))
        XCTAssertFalse(owner.beginDownload(
            manifestRequestID: 53,
            transferID: 63,
            destinationOwner: second
        ))
        try completeEmptyManifest(owner, epoch: 8, requestID: 52)

        XCTAssertTrue(owner.beginDownload(
            manifestRequestID: 53,
            transferID: 63,
            destinationOwner: second
        ))
        XCTAssertFalse(owner.beginDownload(
            manifestRequestID: 54,
            transferID: 62,
            destinationOwner: second
        ))
        XCTAssertEqual(owner.snapshot(), ViewerFileTransferSessionSnapshot(
            sessionEpoch: 8,
            pendingManifestRequestID: 53,
            pendingTransferID: 63,
            activeTransferIDs: [62],
            isTornDown: false
        ))
    }

    func testRejectedCancelFailsClosedAndDiscardsExactReceiveRoute() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try makeDestination(epoch: 9, directory: directory, token: 111)
        let core = ViewerFileTransferSessionCoreRecorder()
        core.cancelResult = -4
        let events = ViewerFileTransferSessionEventRecorder()
        let owner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 9,
            core: core,
            onEvent: events.handler
        ))
        XCTAssertTrue(owner.beginDownload(
            manifestRequestID: 54,
            transferID: 64,
            destinationOwner: destination
        ))
        try completeEmptyManifest(owner, epoch: 9, requestID: 54)

        XCTAssertFalse(owner.requestCancellation(sessionEpoch: 8, transferID: 64))
        XCTAssertFalse(owner.requestCancellation(sessionEpoch: 9, transferID: 64))
        XCTAssertEqual(core.cancellations, [.init(epoch: 9, transferID: 64)])
        XCTAssertEqual(core.discards, [.init(epoch: 9, transferID: 64)])
        XCTAssertEqual(events.values.last, .finished(
            sessionEpoch: 9,
            transferID: 64,
            outcome: .failed(.coreCommandRejected)
        ))
        XCTAssertNil(destination.lease)
        XCTAssertEqual(owner.snapshot().activeTransferIDs, [])
    }

    func testCoreTerminalWithoutReceiveProofFailsProtocolClosed() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try makeDestination(epoch: 10, directory: directory, token: 121)
        let core = ViewerFileTransferSessionCoreRecorder()
        let events = ViewerFileTransferSessionEventRecorder()
        let owner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 10,
            core: core,
            onEvent: events.handler
        ))
        XCTAssertTrue(owner.beginDownload(
            manifestRequestID: 55,
            transferID: 65,
            destinationOwner: destination
        ))
        try completeEmptyManifest(owner, epoch: 10, requestID: 55)

        XCTAssertTrue(owner.observeCore(try terminalEvent(
            epoch: 10,
            transferID: 65,
            kind: .completed,
            failure: .none,
            totalFiles: 1,
            totalBytes: 0
        )))
        XCTAssertEqual(core.cancellations, [.init(epoch: 10, transferID: 65)])
        XCTAssertEqual(core.discards, [.init(epoch: 10, transferID: 65)])
        XCTAssertEqual(events.values.last, .finished(
            sessionEpoch: 10,
            transferID: 65,
            outcome: .failed(.protocolViolation)
        ))
        XCTAssertNil(destination.lease)
    }

    func testManifestFailureClosesOnlyTheAcceptedDestination() throws {
        let directory = try makePrivateDirectory()
        let rejectedDirectory = try makePrivateDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: rejectedDirectory)
        }
        let destination = try makeDestination(epoch: 11, directory: directory, token: 131)
        let rejected = try makeDestination(epoch: 12, directory: rejectedDirectory, token: 132)
        let core = ViewerFileTransferSessionCoreRecorder()
        let events = ViewerFileTransferSessionEventRecorder()
        let owner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 11,
            core: core,
            onEvent: events.handler
        ))

        XCTAssertFalse(owner.beginDownload(
            manifestRequestID: 56,
            transferID: 66,
            destinationOwner: rejected
        ))
        XCTAssertNotNil(rejected.lease)
        XCTAssertTrue(owner.beginDownload(
            manifestRequestID: 56,
            transferID: 66,
            destinationOwner: destination
        ))
        XCTAssertFalse(owner.observeManifest(try manifestEvent(
            epoch: 12,
            requestID: 56,
            status: .unavailable,
            part: .files,
            entries: []
        )))
        XCTAssertTrue(owner.observeManifest(try manifestEvent(
            epoch: 11,
            requestID: 56,
            status: .unavailable,
            part: .files,
            entries: []
        )))
        XCTAssertEqual(events.values.last, .finished(
            sessionEpoch: 11,
            transferID: 66,
            outcome: .failed(.manifest(.unavailable))
        ))
        XCTAssertNil(destination.lease)
        XCTAssertNotNil(rejected.lease)
    }

    func testExactEpochTeardownCancelsActiveAndClosesPendingOwners() throws {
        let firstDirectory = try makePrivateDirectory()
        let secondDirectory = try makePrivateDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let first = try makeDestination(epoch: 13, directory: firstDirectory, token: 141)
        let second = try makeDestination(epoch: 13, directory: secondDirectory, token: 142)
        let core = ViewerFileTransferSessionCoreRecorder()
        let events = ViewerFileTransferSessionEventRecorder()
        let owner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 13,
            core: core,
            onEvent: events.handler
        ))
        XCTAssertTrue(owner.beginDownload(
            manifestRequestID: 57,
            transferID: 67,
            destinationOwner: first
        ))
        try completeEmptyManifest(owner, epoch: 13, requestID: 57)
        XCTAssertTrue(owner.beginDownload(
            manifestRequestID: 58,
            transferID: 68,
            destinationOwner: second
        ))

        XCTAssertFalse(owner.teardown(sessionEpoch: 12))
        XCTAssertTrue(owner.teardown(sessionEpoch: 13))
        XCTAssertFalse(owner.teardown(sessionEpoch: 13))
        XCTAssertEqual(core.cancellations, [.init(epoch: 13, transferID: 67)])
        XCTAssertEqual(core.discards, [.init(epoch: 13, transferID: 67)])
        XCTAssertNil(first.lease)
        XCTAssertNil(second.lease)
        XCTAssertEqual(Array(events.values.suffix(2)), [
            .finished(
                sessionEpoch: 13,
                transferID: 67,
                outcome: .failed(.connectionClosed)
            ),
            .finished(
                sessionEpoch: 13,
                transferID: 68,
                outcome: .failed(.connectionClosed)
            ),
        ])
        XCTAssertEqual(owner.snapshot(), ViewerFileTransferSessionSnapshot(
            sessionEpoch: 13,
            pendingManifestRequestID: nil,
            pendingTransferID: nil,
            activeTransferIDs: [],
            isTornDown: true
        ))
    }

    func testCommandRejectionPreservesUnacceptedOwnerAndClosesStartedOwner() throws {
        let requestDirectory = try makePrivateDirectory()
        let startDirectory = try makePrivateDirectory()
        defer {
            try? FileManager.default.removeItem(at: requestDirectory)
            try? FileManager.default.removeItem(at: startDirectory)
        }
        let requestDestination = try makeDestination(
            epoch: 14,
            directory: requestDirectory,
            token: 151
        )
        let requestCore = ViewerFileTransferSessionCoreRecorder()
        requestCore.requestResult = -4
        let requestEvents = ViewerFileTransferSessionEventRecorder()
        let requestOwner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 14,
            core: requestCore,
            onEvent: requestEvents.handler
        ))

        XCTAssertFalse(requestOwner.beginDownload(
            manifestRequestID: 59,
            transferID: 69,
            destinationOwner: requestDestination
        ))
        XCTAssertNotNil(requestDestination.lease)
        XCTAssertEqual(requestOwner.snapshot().pendingTransferID, nil)
        XCTAssertEqual(requestEvents.values, [])

        let startDestination = try makeDestination(
            epoch: 15,
            directory: startDirectory,
            token: 152
        )
        let startCore = ViewerFileTransferSessionCoreRecorder()
        startCore.startResult = -4
        let startEvents = ViewerFileTransferSessionEventRecorder()
        let startOwner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 15,
            core: startCore,
            onEvent: startEvents.handler
        ))
        XCTAssertTrue(startOwner.beginDownload(
            manifestRequestID: 60,
            transferID: 70,
            destinationOwner: startDestination
        ))
        try completeEmptyManifest(startOwner, epoch: 15, requestID: 60)

        XCTAssertNil(startDestination.lease)
        XCTAssertEqual(startOwner.snapshot().activeTransferIDs, [])
        XCTAssertEqual(startEvents.values.last, .finished(
            sessionEpoch: 15,
            transferID: 70,
            outcome: .failed(.coreCommandRejected)
        ))
    }

    func testRemoteFailureRequiresMatchingReceiveProof() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try makeDestination(epoch: 16, directory: directory, token: 161)
        let core = ViewerFileTransferSessionCoreRecorder()
        let events = ViewerFileTransferSessionEventRecorder()
        let owner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 16,
            core: core,
            onEvent: events.handler
        ))
        XCTAssertTrue(owner.beginDownload(
            manifestRequestID: 61,
            transferID: 71,
            destinationOwner: destination
        ))
        try completeEmptyManifest(owner, epoch: 16, requestID: 61)

        core.emitReceive(.failed(.remote(.unavailable)), transferID: 71)
        XCTAssertTrue(owner.observeCore(try terminalEvent(
            epoch: 16,
            transferID: 71,
            kind: .failed,
            failure: .unavailable,
            totalFiles: 1,
            totalBytes: 0
        )))
        XCTAssertEqual(events.values.suffix(2), [
            .progress(try terminalSnapshot(
                epoch: 16,
                transferID: 71,
                phase: .failed(.unavailable),
                totalFiles: 1,
                totalBytes: 0
            )),
            .finished(
                sessionEpoch: 16,
                transferID: 71,
                outcome: .failed(.receive(.remote(.unavailable)))
            ),
        ])
        XCTAssertNil(destination.lease)
        XCTAssertEqual(core.cancellations, [])
        XCTAssertEqual(core.discards, [])
    }

    func testTeardownWaitsForInFlightManifestCommandBeforeClosingDestination() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try makeDestination(epoch: 18, directory: directory, token: 171)
        let core = ViewerFileTransferSessionCoreRecorder()
        core.blockNextManifestRequest()
        let owner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 18,
            core: core,
            onEvent: { _ in }
        ))
        let beginResult = ViewerFileTransferSessionBoolRecorder()
        let teardownResult = ViewerFileTransferSessionBoolRecorder()
        let beginFinished = DispatchSemaphore(value: 0)
        let teardownFinished = DispatchSemaphore(value: 0)
        defer { core.releaseManifestRequest() }

        DispatchQueue.global().async {
            beginResult.set(owner.beginDownload(
                manifestRequestID: 62,
                transferID: 72,
                destinationOwner: destination
            ))
            beginFinished.signal()
        }
        XCTAssertEqual(
            core.manifestRequestEntered.wait(timeout: .now() + 1),
            .success
        )

        DispatchQueue.global().async {
            teardownResult.set(owner.teardown(sessionEpoch: 18))
            teardownFinished.signal()
        }
        XCTAssertEqual(
            teardownFinished.wait(timeout: .now() + 0.05),
            .timedOut
        )
        XCTAssertNotNil(destination.lease)

        core.releaseManifestRequest()
        XCTAssertEqual(beginFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(teardownFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(beginResult.value, true)
        XCTAssertEqual(teardownResult.value, true)
        XCTAssertNil(destination.lease)
    }

    func testConcurrentDownloadLimitIsEightAndRejectedOwnerStaysOpen() throws {
        var directories: [URL] = []
        defer { directories.forEach { try? FileManager.default.removeItem(at: $0) } }
        let core = ViewerFileTransferSessionCoreRecorder()
        let owner = try XCTUnwrap(ViewerFileTransferSessionOwner(
            sessionEpoch: 17,
            core: core,
            onEvent: { _ in }
        ))

        for index in 0..<ViewerFileTransferSessionOwner.maximumConcurrentDownloads {
            let directory = try makePrivateDirectory()
            directories.append(directory)
            let destination = try makeDestination(
                epoch: 17,
                directory: directory,
                token: UInt64(200 + index)
            )
            let requestID = Int32(100 + index)
            XCTAssertTrue(owner.beginDownload(
                manifestRequestID: requestID,
                transferID: Int32(200 + index),
                destinationOwner: destination
            ))
            try completeEmptyManifest(owner, epoch: 17, requestID: requestID)
        }
        XCTAssertEqual(
            owner.snapshot().activeTransferIDs.count,
            ViewerFileTransferSessionOwner.maximumConcurrentDownloads
        )

        let rejectedDirectory = try makePrivateDirectory()
        directories.append(rejectedDirectory)
        let rejected = try makeDestination(
            epoch: 17,
            directory: rejectedDirectory,
            token: 999
        )
        XCTAssertFalse(owner.beginDownload(
            manifestRequestID: 999,
            transferID: 999,
            destinationOwner: rejected
        ))
        XCTAssertNotNil(rejected.lease)
    }

    private func completeEmptyManifest(
        _ owner: ViewerFileTransferSessionOwner,
        epoch: UInt64,
        requestID: Int32
    ) throws {
        XCTAssertTrue(owner.observeManifest(try manifestEvent(
            epoch: epoch,
            requestID: requestID,
            part: .files,
            entries: [fileEntry(path: "zero.txt", size: 0, modifiedTime: 10)]
        )))
        XCTAssertTrue(owner.observeManifest(try manifestEvent(
            epoch: epoch,
            requestID: requestID,
            part: .emptyDirectories,
            entries: []
        )))
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private func makeDestination(
        epoch: UInt64,
        directory: URL,
        token: UInt64
    ) throws -> ViewerFileTransferDestinationOwner {
        try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: epoch,
            directoryURL: directory,
            leaseToken: token
        ))
    }

    private func fileEntry(
        path: String,
        size: UInt64,
        modifiedTime: UInt64
    ) -> CoreFileTransferListEntry {
        CoreFileTransferListEntry(
            kind: .file,
            relativePath: path,
            size: size,
            modifiedTime: modifiedTime
        )
    }

    private func manifestEvent(
        epoch: UInt64,
        requestID: Int32,
        status: CoreFileTransferListStatus = .success,
        part: CoreFileTransferManifestPartKind,
        entries: [CoreFileTransferListEntry]
    ) throws -> CoreFileTransferManifestEvent {
        try XCTUnwrap(CoreFileTransferManifestEvent(
            sessionEpoch: epoch,
            requestID: requestID,
            status: status,
            part: part,
            entries: entries
        ))
    }

    private func terminalEvent(
        epoch: UInt64,
        transferID: Int32,
        kind: CoreFileTransferEventKind,
        failure: CoreFileTransferFailure,
        totalFiles: UInt32,
        totalBytes: UInt64
    ) throws -> CoreFileTransferEvent {
        try XCTUnwrap(CoreFileTransferEvent(
            sessionEpoch: epoch,
            transferID: transferID,
            sequence: 1,
            kind: kind,
            failure: failure,
            currentFileNumber: nil,
            filesCompleted: kind == .completed ? totalFiles : 0,
            totalFiles: totalFiles,
            bytesCompleted: kind == .completed ? totalBytes : 0,
            totalBytes: totalBytes,
            bytesPerSecond: 0
        ))
    }

    private func queuedSnapshot(
        epoch: UInt64,
        transferID: Int32,
        totalFiles: Int,
        totalBytes: UInt64
    ) throws -> ViewerFileTransferProgressSnapshot {
        ViewerFileTransferProgressSnapshot(
            sessionEpoch: epoch,
            transferID: transferID,
            direction: .download,
            sequence: 0,
            phase: .queued,
            currentFileNumber: nil,
            filesCompleted: 0,
            totalFiles: totalFiles,
            bytesCompleted: 0,
            totalBytes: totalBytes,
            bytesPerSecond: 0
        )
    }

    private func terminalSnapshot(
        epoch: UInt64,
        transferID: Int32,
        phase: ViewerFileTransferProgressPhase,
        totalFiles: Int,
        totalBytes: UInt64
    ) throws -> ViewerFileTransferProgressSnapshot {
        ViewerFileTransferProgressSnapshot(
            sessionEpoch: epoch,
            transferID: transferID,
            direction: .download,
            sequence: 1,
            phase: phase,
            currentFileNumber: nil,
            filesCompleted: phase == .completed ? totalFiles : 0,
            totalFiles: totalFiles,
            bytesCompleted: phase == .completed ? totalBytes : 0,
            totalBytes: totalBytes,
            bytesPerSecond: 0
        )
    }
}

private final class ViewerFileTransferSessionCoreRecorder:
    ViewerFileTransferSessionCore,
    @unchecked Sendable
{
    struct ManifestRequest: Equatable {
        let epoch: UInt64
        let requestID: Int32
    }

    struct Transfer: Equatable {
        let epoch: UInt64
        let transferID: Int32
    }

    struct Start: Equatable {
        let epoch: UInt64
        let manifestRequestID: Int32
        let transferID: Int32
        let destination: ViewerFileTransferDestinationLease?
    }

    private let lock = NSLock()
    var requestResult: Int32 = 0
    var startResult: Int32 = 0
    var cancelResult: Int32 = 0
    private(set) var manifestRequests: [ManifestRequest] = []
    private(set) var starts: [Start] = []
    private(set) var cancellations: [Transfer] = []
    private(set) var discards: [Transfer] = []
    private var receiveCallbacks: [
        Int32: @Sendable (ViewerFileTransferReceiveEvent) -> Void
    ] = [:]
    private var shouldBlockNextManifestRequest = false
    let manifestRequestEntered = DispatchSemaphore(value: 0)
    private let manifestRequestRelease = DispatchSemaphore(value: 0)

    func requestFileTransferRecursiveManifest(
        sessionEpoch: UInt64,
        requestID: Int32
    ) -> Int32 {
        let (result, shouldBlock) = lock.withLock {
            manifestRequests.append(.init(epoch: sessionEpoch, requestID: requestID))
            let shouldBlock = shouldBlockNextManifestRequest
            shouldBlockNextManifestRequest = false
            return (requestResult, shouldBlock)
        }
        if shouldBlock {
            manifestRequestEntered.signal()
            manifestRequestRelease.wait()
        }
        return result
    }

    func startFileTransferDownload(
        _ request: ViewerFileTransferDownloadRequest,
        manifestRequestID: Int32,
        destinationOwner: ViewerFileTransferDestinationOwner,
        onReceiveEvent: @escaping @Sendable (ViewerFileTransferReceiveEvent) -> Void
    ) -> Int32 {
        lock.withLock {
            starts.append(.init(
                epoch: request.sessionEpoch,
                manifestRequestID: manifestRequestID,
                transferID: request.transferID,
                destination: destinationOwner.lease
            ))
            if startResult == 0 {
                receiveCallbacks[request.transferID] = onReceiveEvent
            }
            return startResult
        }
    }

    func cancelFileTransfer(sessionEpoch: UInt64, transferID: Int32) -> Int32 {
        lock.withLock {
            cancellations.append(.init(epoch: sessionEpoch, transferID: transferID))
            return cancelResult
        }
    }

    func discardFileTransferReceive(sessionEpoch: UInt64, transferID: Int32) -> Bool {
        lock.withLock {
            discards.append(.init(epoch: sessionEpoch, transferID: transferID))
            return receiveCallbacks.removeValue(forKey: transferID) != nil
        }
    }

    func emitReceive(_ event: ViewerFileTransferReceiveEvent, transferID: Int32) {
        let callback = lock.withLock { receiveCallbacks[transferID] }
        callback?(event)
    }

    func blockNextManifestRequest() {
        lock.withLock { shouldBlockNextManifestRequest = true }
    }

    func releaseManifestRequest() {
        manifestRequestRelease.signal()
    }
}

private final class ViewerFileTransferSessionBoolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool?

    var value: Bool? {
        lock.withLock { storage }
    }

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }
}

private final class ViewerFileTransferSessionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ViewerFileTransferSessionEvent] = []

    var values: [ViewerFileTransferSessionEvent] {
        lock.withLock { storage }
    }

    lazy var handler: @Sendable (ViewerFileTransferSessionEvent) -> Void = {
        [weak self] event in
        self?.append(event)
    }

    func append(_ event: ViewerFileTransferSessionEvent) {
        lock.withLock { storage.append(event) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
