@testable import CoreBridge
import XCTest

final class ViewerDisplaySelectionInputOwnerTests: XCTestCase {
    func testSelectionRequiresCurrentOnlineCatalogAndQuiescesBeforeAdmission() throws {
        let recorder = ViewerDisplaySelectionInputRecorder()
        let owner = recorder.makeOwner()

        XCTAssertEqual(owner.select(displayIndex: 1), .catalogUnavailable)
        XCTAssertEqual(recorder.actions, [])

        XCTAssertTrue(owner.observeCatalog(try catalog(selected: 0)))
        recorder.admissionStatus = 0
        let result = owner.select(displayIndex: 1)
        let request = try XCTUnwrap(result.request)

        XCTAssertEqual(request.connectionEpoch, 7)
        XCTAssertEqual(request.commandID, 1)
        XCTAssertEqual(request.catalogRevision, 3)
        XCTAssertEqual(request.displayIndex, 1)
        XCTAssertEqual(recorder.actions, [.quiesce, .admit(request)])
        XCTAssertTrue(owner.snapshot().inputQuiesced)
        XCTAssertEqual(owner.snapshot().pendingRequest, request)
        XCTAssertEqual(owner.select(displayIndex: 0), .selectionPending)
    }

    func testAdmissionRejectionRestoresInputOnlyWhenThisAttemptQuiescedIt() throws {
        let recorder = ViewerDisplaySelectionInputRecorder()
        recorder.admissionStatus = -4
        let owner = recorder.makeOwner()
        XCTAssertTrue(owner.observeCatalog(try catalog(selected: 0)))

        XCTAssertEqual(owner.select(displayIndex: 1), .coreRejected(-4))
        XCTAssertEqual(recorder.actions.count, 3)
        XCTAssertEqual(recorder.actions[0], .quiesce)
        XCTAssertEqual(recorder.actions[2], .resume)
        XCTAssertFalse(owner.snapshot().inputQuiesced)
        XCTAssertNil(owner.snapshot().pendingRequest)
    }

    func testOnlyExactSuccessfulTerminalUnderCurrentCatalogResumesInput() throws {
        let recorder = ViewerDisplaySelectionInputRecorder()
        let owner = recorder.makeOwner()
        XCTAssertTrue(owner.observeCatalog(try catalog(selected: 0)))
        let request = try XCTUnwrap(owner.select(displayIndex: 1).request)

        let stale = try selectionEvent(
            request: request,
            commandID: request.commandID + 1,
            result: .selected,
            failure: .none
        )
        XCTAssertEqual(owner.observeSelection(stale), .ignored)
        XCTAssertTrue(owner.snapshot().inputQuiesced)

        let selected = try selectionEvent(
            request: request,
            result: .selected,
            failure: .none
        )
        XCTAssertEqual(owner.observeSelection(selected), .awaitingCatalog)
        XCTAssertTrue(owner.snapshot().inputQuiesced)
        XCTAssertTrue(owner.observeCatalog(try catalog(selected: 1)))

        XCTAssertFalse(owner.snapshot().inputQuiesced)
        XCTAssertNil(owner.snapshot().pendingRequest)
        XCTAssertEqual(recorder.actions.last, .resume)
    }

    func testFailureKeepsInputQuiescedUntilRetryGetsExactSuccess() throws {
        let recorder = ViewerDisplaySelectionInputRecorder()
        let owner = recorder.makeOwner()
        XCTAssertTrue(owner.observeCatalog(try catalog(selected: 0)))
        let first = try XCTUnwrap(owner.select(displayIndex: 1).request)

        let failed = try selectionEvent(
            request: first,
            result: .failed,
            failure: .remoteSelectionDrift
        )
        XCTAssertEqual(
            owner.observeSelection(failed),
            .failed(.remoteSelectionDrift)
        )
        XCTAssertTrue(owner.snapshot().inputQuiesced)
        XCTAssertNil(owner.snapshot().pendingRequest)

        let retry = try XCTUnwrap(owner.select(displayIndex: 0).request)
        XCTAssertEqual(retry.commandID, 2)
        XCTAssertEqual(recorder.actions.filter { $0 == .quiesce }.count, 1)
        let alreadySelected = try selectionEvent(
            request: retry,
            result: .alreadySelected,
            failure: .none
        )
        XCTAssertEqual(owner.observeSelection(alreadySelected), .resumed)
        XCTAssertFalse(owner.snapshot().inputQuiesced)
        XCTAssertEqual(recorder.actions.last, .resume)
    }

    func testStopNeverResumesAndRejectsLateEvents() throws {
        let recorder = ViewerDisplaySelectionInputRecorder()
        let owner = recorder.makeOwner()
        XCTAssertTrue(owner.observeCatalog(try catalog(selected: 0)))
        let request = try XCTUnwrap(owner.select(displayIndex: 1).request)

        owner.stop()
        XCTAssertTrue(owner.snapshot().stopped)
        XCTAssertTrue(owner.snapshot().inputQuiesced)
        XCTAssertEqual(recorder.actions.last, .admit(request))
        XCTAssertFalse(owner.observeCatalog(try catalog(selected: 1)))
        XCTAssertEqual(
            owner.observeSelection(try selectionEvent(
                request: request,
                result: .selected,
                failure: .none
            )),
            .ignored
        )
    }

    func testProductCompositionRoutesCallbacksAndAllViewerInputThroughOneGate() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(contentsOf: repository.appendingPathComponent(
            "Sources/RustDeskNative/RustDeskNativeApp.swift"
        ))
        let view = try String(contentsOf: repository.appendingPathComponent(
            "Sources/RustDeskNative/ViewerMetalView.swift"
        ))
        let exclusive = try String(contentsOf: repository.appendingPathComponent(
            "Sources/RustDeskNative/ExclusiveKeyboardController.swift"
        ))

        for marker in [
            "ViewerDisplaySelectionInputOwner(",
            "onDisplayCatalog: {",
            "onDisplaySelection: {",
            "handleViewerDisplayCatalog(",
            "handleViewerDisplaySelection(",
            "releaseAllInputForDisplaySelection()",
            "resumeInputAfterDisplaySelection()",
            "private func selectViewerDisplay(",
            "private func stopViewerDisplaySelectionInput()",
        ] {
            XCTAssertTrue(app.contains(marker), "missing App marker: \(marker)")
        }
        for marker in [
            "private var displaySelectionInputQuiesced = false",
            "guard keyboardInputEnabled, !displaySelectionInputQuiesced else { return }",
            "guard !displaySelectionInputQuiesced else { return }",
            "func releaseAllInputForDisplaySelection()",
            "pendingMove = nil",
            "func resumeInputAfterDisplaySelection()",
        ] {
            XCTAssertTrue(view.contains(marker), "missing Viewer marker: \(marker)")
        }
        XCTAssertGreaterThanOrEqual(
            view.components(separatedBy:
                "guard keyboardInputEnabled, !displaySelectionInputQuiesced else { return }"
            ).count - 1,
            6
        )
        for marker in [
            "private var displaySelectionInputQuiesced = false",
            "!displaySelectionInputQuiesced",
            "func setDisplaySelectionInputQuiesced(_ quiesced: Bool)",
            "preserveIntent: true",
        ] {
            XCTAssertTrue(exclusive.contains(marker), "missing exclusive marker: \(marker)")
        }
    }

    private func catalog(selected: UInt32) throws -> CoreDisplayCatalogEvent {
        try XCTUnwrap(CoreDisplayCatalogEvent(
            connectionEpoch: 7,
            catalogRevision: 3,
            status: .available,
            selectedDisplayIndex: selected,
            entries: [
                try entry(index: 0, name: "Built-in"),
                try entry(index: 1, name: "External"),
            ]
        ))
    }

    private func entry(index: UInt32, name: String) throws -> CoreDisplayCatalogEntry {
        try XCTUnwrap(CoreDisplayCatalogEntry(
            displayIndex: index,
            x: Int32(index) * 1920,
            y: 0,
            width: 1920,
            height: 1080,
            online: true,
            scale: 2,
            name: name
        ))
    }

    private func selectionEvent(
        request: CoreDisplaySelectionRequest,
        commandID: UInt64? = nil,
        result: CoreDisplaySelectionResult,
        failure: CoreDisplaySelectionFailure
    ) throws -> CoreDisplaySelectionEvent {
        try XCTUnwrap(CoreDisplaySelectionEvent(
            connectionEpoch: request.connectionEpoch,
            commandID: commandID ?? request.commandID,
            catalogRevision: request.catalogRevision,
            displayIndex: request.displayIndex,
            result: result,
            failure: failure
        ))
    }
}

private final class ViewerDisplaySelectionInputRecorder: @unchecked Sendable {
    enum Action: Equatable {
        case quiesce
        case admit(CoreDisplaySelectionRequest)
        case resume
    }

    var admissionStatus: Int32 = 0
    private(set) var actions: [Action] = []

    func makeOwner() -> ViewerDisplaySelectionInputOwner {
        ViewerDisplaySelectionInputOwner(
            sendSelection: { [weak self] request in
                guard let self else { return -3 }
                self.actions.append(.admit(request))
                return self.admissionStatus
            },
            quiesceInput: { [weak self] in self?.actions.append(.quiesce) },
            resumeInput: { [weak self] in self?.actions.append(.resume) }
        )
    }
}

private extension ViewerDisplaySelectionInputResult {
    var request: CoreDisplaySelectionRequest? {
        guard case .admitted(let request) = self else { return nil }
        return request
    }
}
