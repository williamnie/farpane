@testable import CoreBridge
import Foundation
import XCTest

final class ViewerFileTransferProductCompositionTests: XCTestCase {
    func testProjectsDedicatedConfigurationAndRoutesOneCompletedDownload() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = ViewerFileTransferProductCoreRecorder()
        let events = ViewerFileTransferProductEventRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 31,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: events.handler
        ))

        XCTAssertTrue(composition.start(baseConfiguration: baseConfiguration()))
        let projected = try XCTUnwrap(core.connectedConfiguration)
        XCTAssertEqual(projected.rendezvousServer, "127.0.0.1:21116")
        XCTAssertEqual(projected.serverPublicKey, "public-key")
        XCTAssertEqual(projected.peerID, "123456789")
        XCTAssertEqual(projected.password, "temporary-password")
        XCTAssertTrue(projected.forceRelay)
        XCTAssertFalse(projected.receiveClipboardText)
        XCTAssertFalse(projected.sendClipboardText)
        XCTAssertFalse(projected.receiveClipboardRichText)
        XCTAssertFalse(projected.sendClipboardRichText)
        XCTAssertFalse(projected.receiveClipboardImage)
        XCTAssertFalse(projected.sendClipboardImage)
        XCTAssertTrue(projected.fileTransferEnabled)
        XCTAssertEqual(projected.fileTransferSessionEpoch, 31)
        XCTAssertEqual(composition.snapshot().phase, .connecting)

        core.emitState(.streaming)
        XCTAssertEqual(composition.snapshot().phase, .ready)
        XCTAssertEqual(events.values.first, .connectionReady(sessionEpoch: 31))

        XCTAssertEqual(composition.beginDownload(destinationDirectory: directory), 1)
        XCTAssertEqual(core.manifestRequests, [.init(epoch: 31, requestID: 1)])
        core.emitManifest(try manifestEvent(
            part: .files,
            entries: [fileEntry(path: "empty.txt", size: 0)]
        ))
        core.emitManifest(try manifestEvent(
            part: .emptyDirectories,
            entries: []
        ))
        XCTAssertEqual(core.starts.map(\.transferID), [1])

        core.emitReceive(.fileCommitted(fileNumber: 0), transferID: 1)
        core.emitReceive(.completed, transferID: 1)
        core.emitTransfer(try terminalEvent(kind: .completed, failure: .none))

        XCTAssertEqual(events.values.last, .transfer(.finished(
            sessionEpoch: 31,
            transferID: 1,
            outcome: .completed
        )))
    }

    func testExplicitTeardownCancelsAndDiscardsBeforeDisconnect() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = ViewerFileTransferProductCoreRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 32,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: { _ in }
        ))
        XCTAssertTrue(composition.start(baseConfiguration: baseConfiguration()))
        core.emitState(.streaming)
        XCTAssertEqual(composition.beginDownload(destinationDirectory: directory), 1)
        core.emitManifest(try manifestEvent(
            epoch: 32,
            part: .files,
            entries: [fileEntry(path: "pending.txt", size: 4)]
        ))
        core.emitManifest(try manifestEvent(
            epoch: 32,
            part: .emptyDirectories,
            entries: []
        ))

        XCTAssertTrue(composition.teardown())
        XCTAssertFalse(composition.teardown())
        XCTAssertEqual(core.operations.suffix(3), [
            .cancel(epoch: 32, transferID: 1),
            .discard(epoch: 32, transferID: 1),
            .disconnect,
        ])
        XCTAssertEqual(composition.snapshot().phase, .tornDown)

        core.emitManifest(try manifestEvent(
            epoch: 32,
            part: .files,
            entries: []
        ))
        core.emitTransfer(try terminalEvent(
            epoch: 32,
            kind: .cancelled,
            failure: .none
        ))
        XCTAssertEqual(composition.snapshot().phase, .tornDown)
    }

    func testTerminalConnectionFailsClosedAndRejectsFurtherDownloads() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = ViewerFileTransferProductCoreRecorder()
        let events = ViewerFileTransferProductEventRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 33,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: events.handler
        ))
        XCTAssertTrue(composition.start(baseConfiguration: baseConfiguration()))

        core.emitState(.authenticationFailed)
        XCTAssertEqual(
            composition.snapshot().phase,
            .failed(.authenticationRejected)
        )
        XCTAssertEqual(events.values.last, .connectionFailed(
            sessionEpoch: 33,
            failure: .authenticationRejected
        ))
        XCTAssertNil(composition.beginDownload(destinationDirectory: directory))
        XCTAssertTrue(composition.teardown())
        XCTAssertEqual(core.disconnectCount, 1)
    }

    func testCoreCreationAndConnectFailureAreStableAndDisconnectOwnedCore() throws {
        enum TestFailure: Error { case unavailable }

        let creationEvents = ViewerFileTransferProductEventRecorder()
        let creation = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 34,
            makeCore: { _ in throw TestFailure.unavailable },
            onEvent: creationEvents.handler
        ))
        XCTAssertFalse(creation.start(baseConfiguration: baseConfiguration()))
        XCTAssertEqual(creation.snapshot().phase, .failed(.coreUnavailable))
        XCTAssertEqual(creationEvents.values, [.connectionFailed(
            sessionEpoch: 34,
            failure: .coreUnavailable
        )])

        let core = ViewerFileTransferProductCoreRecorder()
        core.connectFailure = TestFailure.unavailable
        let connectEvents = ViewerFileTransferProductEventRecorder()
        let connect = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 35,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: connectEvents.handler
        ))
        XCTAssertFalse(connect.start(baseConfiguration: baseConfiguration()))
        XCTAssertEqual(connect.snapshot().phase, .failed(.coreUnavailable))
        XCTAssertEqual(core.disconnectCount, 1)
        XCTAssertEqual(connectEvents.values.last, .connectionFailed(
            sessionEpoch: 35,
            failure: .coreUnavailable
        ))
    }

    func testInvalidEpochUnsafeDestinationAndPreReadyDownloadFailClosed() throws {
        XCTAssertNil(ViewerFileTransferProductComposition(
            sessionEpoch: 0,
            makeCore: { _ in ViewerFileTransferProductCoreRecorder() },
            onEvent: { _ in }
        ))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: directory.path
        )
        let core = ViewerFileTransferProductCoreRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 36,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: { _ in }
        ))
        XCTAssertTrue(composition.start(baseConfiguration: baseConfiguration()))
        XCTAssertNil(composition.beginDownload(destinationDirectory: directory))
        core.emitState(.streaming)
        XCTAssertNil(composition.beginDownload(destinationDirectory: directory))
        XCTAssertTrue(core.manifestRequests.isEmpty)
    }

    func testSynchronousReadyCallbackIsDeferredUntilStartCanTeardownReentrantly() throws {
        let core = ViewerFileTransferProductCoreRecorder()
        core.stateDuringConnect = .streaming
        let reentrant = ViewerFileTransferProductReentrantTeardown()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 37,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: reentrant.handler
        ))
        reentrant.composition = composition

        XCTAssertFalse(composition.start(baseConfiguration: baseConfiguration()))
        XCTAssertEqual(composition.snapshot().phase, .tornDown)
        XCTAssertEqual(core.disconnectCount, 1)
    }

    func testExplicitDownloadActionPinsDestinationAndStartsOnlyAfterReady() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = ViewerFileTransferProductCoreRecorder()
        let events = ViewerFileTransferProductEventRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 38,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: events.handler
        ))

        XCTAssertEqual(
            composition.requestDownload(
                baseConfiguration: baseConfiguration(),
                destinationDirectory: directory
            ),
            .accepted(transferID: 1)
        )
        XCTAssertEqual(composition.snapshot().queuedTransferID, 1)
        XCTAssertTrue(core.manifestRequests.isEmpty)

        core.emitState(.streaming)

        XCTAssertNil(composition.snapshot().queuedTransferID)
        XCTAssertEqual(core.manifestRequests, [.init(epoch: 38, requestID: 1)])
        XCTAssertEqual(events.values.prefix(2), [
            .connectionReady(sessionEpoch: 38),
            .transfer(.manifestRequested(
                sessionEpoch: 38,
                requestID: 1,
                transferID: 1
            )),
        ])
    }

    func testQueuedDownloadActionCanBeCancelledBeforeConnectionIsReady() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = ViewerFileTransferProductCoreRecorder()
        let events = ViewerFileTransferProductEventRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 39,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: events.handler
        ))
        XCTAssertEqual(
            composition.requestDownload(
                baseConfiguration: baseConfiguration(),
                destinationDirectory: directory
            ),
            .accepted(transferID: 1)
        )

        XCTAssertTrue(composition.requestCancellation(transferID: 1))
        XCTAssertNil(composition.snapshot().queuedTransferID)
        core.emitState(.streaming)

        XCTAssertTrue(core.manifestRequests.isEmpty)
        XCTAssertEqual(events.values.last, .connectionReady(sessionEpoch: 39))
        XCTAssertTrue(events.values.contains(.transfer(.finished(
            sessionEpoch: 39,
            transferID: 1,
            outcome: .cancelled
        ))))
    }

    func testDownloadActionRejectsUnsafeDestinationAndSynchronousFailure() throws {
        let unsafeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: unsafeDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: unsafeDirectory) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: unsafeDirectory.path
        )
        let core = ViewerFileTransferProductCoreRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 40,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: { _ in }
        ))
        XCTAssertEqual(
            composition.requestDownload(
                baseConfiguration: baseConfiguration(),
                destinationDirectory: unsafeDirectory
            ),
            .destinationRejected
        )
        XCTAssertNil(core.connectedConfiguration)

        let privateDirectory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: privateDirectory) }
        core.stateDuringConnect = .authenticationFailed
        XCTAssertEqual(
            composition.requestDownload(
                baseConfiguration: baseConfiguration(),
                destinationDirectory: privateDirectory
            ),
            .unavailable
        )
        XCTAssertEqual(
            composition.snapshot().phase,
            .failed(.authenticationRejected)
        )
        XCTAssertNil(composition.snapshot().queuedTransferID)
        XCTAssertTrue(core.manifestRequests.isEmpty)
    }

    func testExplicitUploadActionPinsSourceAndStartsOnlyAfterReady() throws {
        let source = try makeSourceFile(contents: Data("hello".utf8))
        defer { try? FileManager.default.removeItem(at: source) }
        let core = ViewerFileTransferProductCoreRecorder()
        let events = ViewerFileTransferProductEventRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 41,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: events.handler
        ))

        XCTAssertEqual(
            composition.requestFileTransferUpload(
                baseConfiguration: baseConfiguration(),
                selectedURLs: [source]
            ),
            .accepted(transferID: 1)
        )
        XCTAssertEqual(composition.snapshot().queuedTransferID, 1)
        XCTAssertTrue(core.uploadStarts.isEmpty)

        core.emitState(.streaming)

        XCTAssertNil(composition.snapshot().queuedTransferID)
        XCTAssertEqual(core.uploadStarts, [
            .init(epoch: 41, transferID: 1),
        ])
        guard case .transfer(.progress(let queued)) = events.values.last else {
            return XCTFail("expected queued upload progress")
        }
        XCTAssertEqual(queued.direction, .upload)
        XCTAssertEqual(queued.totalFiles, 1)
        XCTAssertEqual(queued.totalBytes, 5)

        core.emitTransfer(try uploadEvent(
            epoch: 41,
            sequence: 1,
            kind: .completed,
            filesCompleted: 1,
            bytesCompleted: 5,
            totalBytes: 5
        ))
        XCTAssertEqual(events.values.last, .transfer(.finished(
            sessionEpoch: 41,
            transferID: 1,
            outcome: .completed
        )))
    }

    func testQueuedUploadCanBeCancelledAndUnsafeSourceFailsClosed() throws {
        let source = try makeSourceFile(contents: Data("cancel".utf8))
        defer { try? FileManager.default.removeItem(at: source) }
        let core = ViewerFileTransferProductCoreRecorder()
        let events = ViewerFileTransferProductEventRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 42,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: events.handler
        ))
        XCTAssertEqual(
            composition.requestFileTransferUpload(
                baseConfiguration: baseConfiguration(),
                selectedURLs: [source]
            ),
            .accepted(transferID: 1)
        )
        XCTAssertTrue(composition.requestCancellation(transferID: 1))
        core.emitState(.streaming)
        XCTAssertTrue(core.uploadStarts.isEmpty)
        XCTAssertTrue(events.values.contains(.transfer(.finished(
            sessionEpoch: 42,
            transferID: 1,
            outcome: .cancelled
        ))))

        let unsafe = source.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString)")
        let rejectedCore = ViewerFileTransferProductCoreRecorder()
        let rejected = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 43,
            makeCore: { callbacks in
                rejectedCore.callbacks = callbacks
                return rejectedCore
            },
            onEvent: { _ in }
        ))
        XCTAssertEqual(
            rejected.requestFileTransferUpload(
                baseConfiguration: baseConfiguration(),
                selectedURLs: [unsafe]
            ),
            .sourceRejected
        )
        XCTAssertNil(rejectedCore.connectedConfiguration)
    }

    func testActiveUploadCancellationWaitsForExactTerminalEvent() throws {
        let source = try makeSourceFile(contents: Data("cancel".utf8))
        defer { try? FileManager.default.removeItem(at: source) }
        let core = ViewerFileTransferProductCoreRecorder()
        let events = ViewerFileTransferProductEventRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 44,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: events.handler
        ))
        XCTAssertEqual(
            composition.requestFileTransferUpload(
                baseConfiguration: baseConfiguration(),
                selectedURLs: [source]
            ),
            .accepted(transferID: 1)
        )
        core.emitState(.streaming)

        XCTAssertTrue(composition.requestCancellation(transferID: 1))
        XCTAssertTrue(core.operations.contains(.cancel(
            epoch: 44,
            transferID: 1
        )))
        guard case .transfer(.progress(let cancelling)) = events.values.last else {
            return XCTFail("expected cancelling progress")
        }
        XCTAssertEqual(cancelling.phase, .cancelling)

        core.emitTransfer(try uploadEvent(
            epoch: 44,
            sequence: 1,
            kind: .cancelled,
            filesCompleted: 0,
            bytesCompleted: 0,
            totalBytes: 6
        ))
        XCTAssertEqual(events.values.last, .transfer(.finished(
            sessionEpoch: 44,
            transferID: 1,
            outcome: .cancelled
        )))
    }

    func testUploadProtocolViolationCancelsDiscardsAndFailsClosed() throws {
        let source = try makeSourceFile(contents: Data("guard".utf8))
        defer { try? FileManager.default.removeItem(at: source) }
        let core = ViewerFileTransferProductCoreRecorder()
        let events = ViewerFileTransferProductEventRecorder()
        let composition = try XCTUnwrap(ViewerFileTransferProductComposition(
            sessionEpoch: 45,
            makeCore: { callbacks in
                core.callbacks = callbacks
                return core
            },
            onEvent: events.handler
        ))
        XCTAssertEqual(
            composition.requestFileTransferUpload(
                baseConfiguration: baseConfiguration(),
                selectedURLs: [source]
            ),
            .accepted(transferID: 1)
        )
        core.emitState(.streaming)
        core.emitTransfer(try uploadEvent(
            epoch: 45,
            sequence: 1,
            kind: .progress,
            filesCompleted: 0,
            bytesCompleted: 1,
            totalBytes: 99
        ))

        XCTAssertEqual(core.operations.suffix(2), [
            .cancel(epoch: 45, transferID: 1),
            .discardUpload(epoch: 45, transferID: 1),
        ])
        XCTAssertEqual(events.values.last, .transfer(.finished(
            sessionEpoch: 45,
            transferID: 1,
            outcome: .failed(.protocolViolation)
        )))
    }

    private func baseConfiguration() -> CoreConnectionConfig {
        CoreConnectionConfig(
            rendezvousServer: "127.0.0.1:21116",
            serverPublicKey: "public-key",
            peerID: "123456789",
            password: "temporary-password",
            forceRelay: true,
            receiveClipboardText: true,
            sendClipboardText: true,
            receiveClipboardRichText: true,
            sendClipboardRichText: true,
            receiveClipboardImage: true,
            sendClipboardImage: true
        )
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private func makeSourceFile(contents: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).txt")
        try contents.write(to: file, options: .withoutOverwriting)
        return file
    }

    private func fileEntry(path: String, size: UInt64) -> CoreFileTransferListEntry {
        CoreFileTransferListEntry(
            kind: .file,
            relativePath: path,
            size: size,
            modifiedTime: 10
        )
    }

    private func manifestEvent(
        epoch: UInt64 = 31,
        part: CoreFileTransferManifestPartKind,
        entries: [CoreFileTransferListEntry]
    ) throws -> CoreFileTransferManifestEvent {
        try XCTUnwrap(CoreFileTransferManifestEvent(
            sessionEpoch: epoch,
            requestID: 1,
            status: .success,
            part: part,
            entries: entries
        ))
    }

    private func terminalEvent(
        epoch: UInt64 = 31,
        kind: CoreFileTransferEventKind,
        failure: CoreFileTransferFailure
    ) throws -> CoreFileTransferEvent {
        try XCTUnwrap(CoreFileTransferEvent(
            sessionEpoch: epoch,
            transferID: 1,
            sequence: 1,
            kind: kind,
            failure: failure,
            currentFileNumber: nil,
            filesCompleted: kind == .completed ? 1 : 0,
            totalFiles: 1,
            bytesCompleted: 0,
            totalBytes: kind == .completed ? 0 : 4,
            bytesPerSecond: 0
        ))
    }

    private func uploadEvent(
        epoch: UInt64,
        sequence: UInt64,
        kind: CoreFileTransferEventKind,
        filesCompleted: UInt32,
        bytesCompleted: UInt64,
        totalBytes: UInt64,
        failure: CoreFileTransferFailure = .none
    ) throws -> CoreFileTransferEvent {
        try XCTUnwrap(CoreFileTransferEvent(
            sessionEpoch: epoch,
            transferID: 1,
            sequence: sequence,
            kind: kind,
            failure: failure,
            currentFileNumber: nil,
            filesCompleted: filesCompleted,
            totalFiles: 1,
            bytesCompleted: bytesCompleted,
            totalBytes: totalBytes,
            bytesPerSecond: 0
        ))
    }
}

private final class ViewerFileTransferProductCoreRecorder:
    ViewerFileTransferProductCore,
    @unchecked Sendable
{
    struct ManifestRequest: Equatable {
        let epoch: UInt64
        let requestID: Int32
    }

    struct Start: Equatable {
        let epoch: UInt64
        let transferID: Int32
    }

    enum Operation: Equatable {
        case cancel(epoch: UInt64, transferID: Int32)
        case discard(epoch: UInt64, transferID: Int32)
        case discardUpload(epoch: UInt64, transferID: Int32)
        case disconnect
    }

    private let lock = NSLock()
    var callbacks: ViewerFileTransferProductCoreCallbacks?
    var connectFailure: Error?
    var stateDuringConnect: CoreConnectionState?
    private(set) var connectedConfiguration: CoreConnectionConfig?
    private(set) var manifestRequests: [ManifestRequest] = []
    private(set) var starts: [Start] = []
    private(set) var uploadStarts: [Start] = []
    private(set) var operations: [Operation] = []
    private var receiveCallbacks: [
        Int32: @Sendable (ViewerFileTransferReceiveEvent) -> Void
    ] = [:]

    var disconnectCount: Int {
        lock.withLock { operations.filter { $0 == .disconnect }.count }
    }

    func connect(_ config: CoreConnectionConfig) throws {
        let (failure, state, callbacks) = lock.withLock {
            connectedConfiguration = config
            return (connectFailure, stateDuringConnect, self.callbacks)
        }
        if let failure { throw failure }
        if let state {
            callbacks?.onState(.init(state: state, code: 0, message: "test"))
        }
    }

    func disconnect() {
        lock.withLock { operations.append(.disconnect) }
    }

    func requestFileTransferRecursiveManifest(
        sessionEpoch: UInt64,
        requestID: Int32
    ) -> Int32 {
        lock.withLock {
            manifestRequests.append(.init(epoch: sessionEpoch, requestID: requestID))
        }
        return 0
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
                transferID: request.transferID
            ))
            receiveCallbacks[request.transferID] = onReceiveEvent
        }
        return 0
    }

    func cancelFileTransfer(sessionEpoch: UInt64, transferID: Int32) -> Int32 {
        lock.withLock {
            operations.append(.cancel(epoch: sessionEpoch, transferID: transferID))
        }
        return 0
    }

    func startFileTransferUpload(
        _ request: ViewerFileTransferUploadRequest,
        sourceOwner: ViewerFileTransferUploadSourceOwner
    ) -> Int32 {
        lock.withLock {
            uploadStarts.append(.init(
                epoch: request.sessionEpoch,
                transferID: request.transferID
            ))
        }
        return 0
    }

    func discardFileTransferReceive(sessionEpoch: UInt64, transferID: Int32) -> Bool {
        lock.withLock {
            operations.append(.discard(epoch: sessionEpoch, transferID: transferID))
            return receiveCallbacks.removeValue(forKey: transferID) != nil
        }
    }

    func discardFileTransferUpload(sessionEpoch: UInt64, transferID: Int32) -> Bool {
        lock.withLock {
            operations.append(.discardUpload(
                epoch: sessionEpoch,
                transferID: transferID
            ))
        }
        return true
    }

    func emitState(_ state: CoreConnectionState) {
        let callbacks = lock.withLock { self.callbacks }
        callbacks?.onState(.init(state: state, code: 0, message: "test"))
    }

    func emitManifest(_ event: CoreFileTransferManifestEvent) {
        let callbacks = lock.withLock { self.callbacks }
        callbacks?.onManifest(event)
    }

    func emitTransfer(_ event: CoreFileTransferEvent) {
        let callbacks = lock.withLock { self.callbacks }
        callbacks?.onTransfer(event)
    }

    func emitReceive(_ event: ViewerFileTransferReceiveEvent, transferID: Int32) {
        let callback = lock.withLock { receiveCallbacks[transferID] }
        callback?(event)
    }
}

private final class ViewerFileTransferProductReentrantTeardown:
    @unchecked Sendable
{
    weak var composition: ViewerFileTransferProductComposition?

    lazy var handler: @Sendable (ViewerFileTransferProductEvent) -> Void = {
        [weak self] event in
        if case .connectionReady = event {
            _ = self?.composition?.teardown()
        }
    }
}

private final class ViewerFileTransferProductEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ViewerFileTransferProductEvent] = []

    var values: [ViewerFileTransferProductEvent] {
        lock.withLock { storage }
    }

    lazy var handler: @Sendable (ViewerFileTransferProductEvent) -> Void = {
        [weak self] event in
        self?.lock.withLock { self?.storage.append(event) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
