import XCTest
@testable import VideoPipeline

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        value += UInt64(seconds * 1_000_000_000)
    }
}

final class PipelineMetricsTests: XCTestCase {
    func testHUDUsesRecentFrameRatesAndCurrentQueueDepths() {
        let clock = TestMonotonicClock()
        let metrics = PipelineMetrics(
            inputWidth: 0,
            inputHeight: 0,
            inputFPS: 30,
            selectedGPU: "test-gpu",
            monotonicNow: { clock.now() }
        )

        for index in 0..<3 {
            metrics.recordEncodedPacket(
                codec: "h265",
                format: "annex-b",
                byteCount: 128,
                sequence: UInt64(index),
                timestampUS: UInt64(index + 1),
                isKeyframe: index == 0,
                containsVPS: index == 0,
                containsSPS: index == 0,
                containsPPS: index == 0,
                width: 3840,
                height: 2160
            )
            metrics.recordPresented(milliseconds: 1)
            if index < 2 { clock.advance(seconds: 0.5) }
        }
        metrics.recordSubmitted(queueDepth: 2)
        metrics.recordDecoderQueueDepth(0)
        metrics.recordRendererQueueDepth(2)
        metrics.recordRendererQueueDepth(0)

        var hud = metrics.hudSnapshot()
        XCTAssertEqual(hud.encodedFPS, 2, accuracy: 0.001)
        XCTAssertEqual(hud.presentedFPS, 2, accuracy: 0.001)
        XCTAssertEqual(hud.decoderQueueDepth, 0)
        XCTAssertEqual(hud.rendererQueueDepth, 0)

        clock.advance(seconds: 6)
        hud = metrics.hudSnapshot()
        XCTAssertEqual(hud.encodedFPS, 0)
        XCTAssertEqual(hud.presentedFPS, 0)

        let report = metrics.snapshot(durationOverride: 1)
        XCTAssertEqual(report.maxQueueDepth, 2)
        XCTAssertEqual(report.maxRendererQueueDepth, 2)
    }

    func testRecordsDistinctEncodedFrameRateAndRemoteDimensions() {
        let metrics = PipelineMetrics(
            inputWidth: 0,
            inputHeight: 0,
            inputFPS: 30,
            selectedGPU: "test-gpu",
            source: "rustdesk-live"
        )

        for (sequence, timestamp) in [UInt64(10_000), 10_000, 20_000].enumerated() {
            if sequence == 1 { Thread.sleep(forTimeInterval: 0.002) }
            metrics.recordEncodedPacket(
                codec: "h265",
                format: "annex-b",
                byteCount: 128,
                sequence: UInt64(sequence),
                timestampUS: timestamp,
                isKeyframe: sequence == 0,
                containsVPS: sequence == 0,
                containsSPS: sequence == 0,
                containsPPS: sequence == 0,
                width: 3840,
                height: 2160
            )
        }

        let report = metrics.snapshot(durationOverride: 2)
        XCTAssertEqual(report.schema, "farpane-viewer-pipeline-report")
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.processID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(report.bundleIdentifier.isEmpty)
        XCTAssertFalse(report.buildIdentifier.isEmpty)
        XCTAssertFalse(report.measurementStartedAt.isEmpty)
        XCTAssertGreaterThan(
            report.measurementCompletedMonotonicNanoseconds,
            report.measurementStartedMonotonicNanoseconds
        )
        XCTAssertNil(report.firstPresentationMonotonicNanoseconds)
        XCTAssertNil(report.lastPresentationMonotonicNanoseconds)
        XCTAssertEqual(report.encodedPackets, 3)
        XCTAssertEqual(report.encodedFrames, 2)
        XCTAssertEqual(report.endToEndEncodedFPS, 1)
        XCTAssertGreaterThan(report.measuredEncodedFPS, report.endToEndEncodedFPS)
        XCTAssertEqual(report.remoteEncodedWidth, 3840)
        XCTAssertEqual(report.remoteEncodedHeight, 2160)
        XCTAssertGreaterThan(report.maxPresentationStalenessWhileReceivingMS, 0)
        XCTAssertGreaterThan(report.finalEncodedToPresentationStalenessMS, 0)

        metrics.recordPresented(milliseconds: 1)
        let presentedReport = metrics.snapshot(durationOverride: 2)
        XCTAssertEqual(presentedReport.finalEncodedToPresentationStalenessMS, 0)
        XCTAssertNotNil(presentedReport.firstPresentationMonotonicNanoseconds)
        XCTAssertNotNil(presentedReport.lastPresentationMonotonicNanoseconds)
    }

    func testSeparatesActivePresentationRateFromEndToEndRate() {
        let metrics = PipelineMetrics(
            inputWidth: 0,
            inputHeight: 0,
            inputFPS: 30,
            selectedGPU: "test-gpu"
        )

        metrics.recordPresented(milliseconds: 1)
        Thread.sleep(forTimeInterval: 0.02)
        metrics.recordPresented(milliseconds: 1)

        let report = metrics.snapshot(durationOverride: 1)
        XCTAssertEqual(report.endToEndPresentedFPS, 2)
        XCTAssertGreaterThan(report.measuredFPS, report.endToEndPresentedFPS)
    }

    func testPreservesLastAvailableCoreNetworkMetrics() {
        let metrics = PipelineMetrics(
            inputWidth: 0,
            inputHeight: 0,
            inputFPS: 30,
            selectedGPU: "test-gpu",
            source: "rustdesk-live"
        )

        metrics.recordCoreMetrics(remoteFPS: 24, networkDelayMS: 7, targetBitrate: 2_000_000)
        metrics.recordCoreMetrics(remoteFPS: 0, networkDelayMS: -1, targetBitrate: 0)

        let report = metrics.snapshot(durationOverride: 1)
        XCTAssertEqual(report.coreRemoteFPS, 24)
        XCTAssertEqual(report.coreNetworkDelayMS, 7)
        XCTAssertEqual(report.coreTargetBitrate, 2_000_000)
    }

    func testRecordsAsynchronousDecoderRecoveryDiagnostics() {
        let metrics = PipelineMetrics(
            inputWidth: 0,
            inputHeight: 0,
            inputFPS: 30,
            selectedGPU: "test-gpu",
            source: "rustdesk-live"
        )

        metrics.recordDecodeError(status: -12_909)
        metrics.recordDecoderReset(status: -12_909)
        metrics.recordReferenceFrameDrop()
        metrics.recordBackpressureWait(milliseconds: 12.5)
        metrics.recordDecoderReset(status: nil)
        metrics.recordKeyframeRequest()
        metrics.recordKeyframeRequest()
        metrics.recordRendererQueueDepth(1)
        metrics.recordRendererQueueDepth(2)
        metrics.recordPresented(milliseconds: 1)
        Thread.sleep(forTimeInterval: 0.002)
        metrics.recordPresented(milliseconds: 1)

        let report = metrics.snapshot(durationOverride: 1)
        XCTAssertEqual(report.decodeErrors, 1)
        XCTAssertEqual(report.firstDecodeErrorStatus, -12_909)
        XCTAssertEqual(report.lastDecodeErrorStatus, -12_909)
        XCTAssertEqual(report.referenceFrameDrops, 1)
        XCTAssertEqual(report.backpressureWaits, 1)
        XCTAssertEqual(report.maxBackpressureWaitMS, 12.5)
        XCTAssertEqual(report.droppedFrames, 1)
        XCTAssertEqual(report.decoderResets, 2)
        XCTAssertEqual(report.keyframeRequests, 2)
        XCTAssertEqual(report.maxRendererQueueDepth, 2)
        XCTAssertGreaterThan(report.maxPresentationGapMS, 0)
        XCTAssertGreaterThanOrEqual(report.finalPresentationStalenessMS, 0)
        XCTAssertGreaterThanOrEqual(report.maxPresentationStalenessWhileReceivingMS, 0)
        XCTAssertGreaterThanOrEqual(report.finalEncodedToPresentationStalenessMS, 0)
    }

    func testPersistsPhase3InputAndManualFeedbackEvidence() {
        let metrics = PipelineMetrics(
            inputWidth: 0,
            inputHeight: 0,
            inputFPS: 30,
            selectedGPU: "test-gpu",
            source: "rustdesk-live"
        )
        for category in ["pointer-move", "button-down", "button-up", "scroll", "key-down", "key-up"] {
            metrics.recordInput(category: category, accepted: true)
        }
        metrics.recordInput(category: "key-down", accepted: false)
        metrics.recordFullscreenToggle()
        metrics.recordHUDToggle()
        metrics.recordExclusiveKeyboardActivation()
        metrics.recordExclusiveKeyboardFailure()
        metrics.recordFunctionalCheck("click", passed: true)

        let report = metrics.snapshot(durationOverride: 1)
        XCTAssertEqual(report.inputPointerMoves, 1)
        XCTAssertEqual(report.inputButtonDowns, 1)
        XCTAssertEqual(report.inputButtonUps, 1)
        XCTAssertEqual(report.inputScrollEvents, 1)
        XCTAssertEqual(report.inputKeyDowns, 1)
        XCTAssertEqual(report.inputKeyUps, 1)
        XCTAssertEqual(report.inputRejectedEvents, 1)
        XCTAssertEqual(report.fullscreenToggles, 1)
        XCTAssertEqual(report.hudToggles, 1)
        XCTAssertEqual(report.exclusiveKeyboardActivations, 1)
        XCTAssertEqual(report.exclusiveKeyboardFailures, 1)
        XCTAssertEqual(report.functionalChecks["click"], true)
    }
}
