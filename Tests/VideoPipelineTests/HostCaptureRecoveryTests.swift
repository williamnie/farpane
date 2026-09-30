import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import XCTest

@testable import VideoPipeline

final class HostCaptureRecoveryTests: XCTestCase {
    func testAuthorizedCaptureProducesFramesAfterInjectedSystemStop() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is not granted to the test process")
        }
        let initialFrame = expectation(description: "原始采集首帧")
        let recoveredFrame = expectation(description: "恢复采集首帧")
        let probe = LiveCaptureRecoveryProbe(frames: [initialFrame, recoveredFrame])
        let recovery = HostCaptureRecovery(
            configuration: HostCaptureConfiguration(
                displayIndex: 0, width: 256, height: 144, framesPerSecond: 30),
            factory: { probe.make(displayID: $0, onStopped: $1) },
            onFailure: { error in XCTFail("采集恢复失败: \(error)") }, delay: { _ in })
        do {
            try await recovery.start()
            await fulfillment(of: [initialFrame], timeout: 5)
            let first = try XCTUnwrap(probe.sessions.first)
            // 仅关闭本测试创建的流，再注入已观察到的系统停止错误，不触碰正在运行的 Host。
            await first.0.stop()
            first.1(NSError(domain: SCStreamErrorDomain, code: -3821))
            await fulfillment(of: [recoveredFrame], timeout: 5)
            XCTAssertEqual(probe.sessions.count, 2)
            XCTAssertEqual(
                probe.sessions.first?.0.capturedDisplayID, probe.sessions.last?.0.capturedDisplayID)
            let timestamps = probe.timestamps
            XCTAssertEqual(timestamps.count, 2)
            if timestamps.count == 2 {
                XCTAssertGreaterThan(CMTimeCompare(timestamps[1], timestamps[0]), 0)
            }
        } catch {
            await recovery.stop()
            throw error
        }
        await recovery.stop()
    }

    func testSystemStopDuringInitialStartHandsOffToRecovery() async throws {
        let resumed = expectation(description: "首帧前系统停止也可恢复")
        let factory = CaptureRecoveryFactory(onStart: { index, session in
            if index == 0 {
                session.fail(code: -3821)
                throw HostScreenCaptureError.streamStopped("synthetic initial stop")
            }
        })
        let recovery = makeRecovery(
            factory: factory, onEvent: { if $0 == .resumed { resumed.fulfill() } },
            onFailure: { _ in XCTFail("首帧前系统停止不应终止媒体路由") })
        try await recovery.start()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(factory.sessions.count, 2)
        await recovery.stop()
    }

    func testSystemStopThrownByReplacementStartIsRetried() async throws {
        let resumed = expectation(description: "重建时系统仍忙，继续退避")
        let factory = CaptureRecoveryFactory(onStart: { index, _ in
            if index == 1 { throw NSError(domain: SCStreamErrorDomain, code: -3821) }
        })
        let recorder = CaptureRecoveryRecorder()
        let recovery = makeRecovery(
            factory: factory, onEvent: { if $0 == .resumed { resumed.fulfill() } },
            onFailure: { _ in XCTFail("可恢复的启动错误不应终止媒体路由") }, delay: { recorder.recordDelay($0) })
        try await recovery.start()
        try XCTUnwrap(factory.sessions.first).fail(code: -3821)
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(factory.sessions.count, 3)
        XCTAssertEqual(recorder.delays, [1_000_000_000, 2_000_000_000])
        await recovery.stop()
    }

    func testRecoveryBudgetExpiresAfterHealthyInterval() async throws {
        let resumed = (0..<4).map { expectation(description: "第 \($0 + 1) 次恢复") }
        let recorder = CaptureRecoveryRecorder()
        let clock = CaptureRecoveryClock()
        let factory = CaptureRecoveryFactory()
        let recovery = makeRecovery(
            factory: factory,
            onEvent: { event in
                recorder.record(event)
                if event == .resumed {
                    resumed[recorder.events.filter { $0 == .resumed }.count - 1].fulfill()
                }
            }, onFailure: { _ in XCTFail("健康运行后应允许再次恢复") }, delay: { recorder.recordDelay($0) },
            now: { clock.value })
        try await recovery.start()
        for index in 0..<4 {
            try XCTUnwrap(factory.sessions.last).fail(code: -3821)
            await fulfillment(of: [resumed[index]], timeout: 1)
            clock.advance()
        }
        XCTAssertEqual(factory.sessions.count, 5)
        XCTAssertEqual(recorder.delays, Array(repeating: 1_000_000_000, count: 4))
        await recovery.stop()
    }

    func testUserStopPermissionDenialAndUnknownErrorsDoNotRestart() async throws {
        for error in [
            NSError(domain: SCStreamErrorDomain, code: -3817),
            NSError(domain: SCStreamErrorDomain, code: -3801),
            NSError(domain: "untrusted", code: -3821),
        ] {
            let failed = expectation(description: "不自动重开采集")
            let factory = CaptureRecoveryFactory()
            let recovery = makeRecovery(factory: factory, onFailure: { _ in failed.fulfill() })
            try await recovery.start()
            try XCTUnwrap(factory.sessions.first).fail(error)
            await fulfillment(of: [failed], timeout: 1)
            XCTAssertEqual(factory.sessions.count, 1)
            await recovery.stop()
        }
    }

    func testRepeatedSystemStopsUseBoundedBackoff() async throws {
        let failed = expectation(description: "达到重试上限")
        let recorder = CaptureRecoveryRecorder()
        let factory = CaptureRecoveryFactory(onStart: { index, session in
            if index > 0 { session.fail(code: -3821) }
        })
        let recovery = makeRecovery(
            factory: factory, onEvent: { recorder.record($0) },
            onFailure: { _ in failed.fulfill() }, delay: { recorder.recordDelay($0) })
        try await recovery.start()
        try XCTUnwrap(factory.sessions.first).fail(code: -3821)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(factory.sessions.count, 4)
        XCTAssertEqual(recorder.delays, [1_000_000_000, 2_000_000_000, 4_000_000_000])
        XCTAssertEqual(recorder.events.filter { $0 == .exhausted }.count, 1)
        XCTAssertFalse(recorder.events.contains(.resumed))
        await recovery.stop()
    }

    func testCancelWhileWaitingPreventsRestart() async throws {
        let waiting = expectation(description: "等待退避")
        let gate = CaptureRecoveryGate()
        let factory = CaptureRecoveryFactory()
        let recorder = CaptureRecoveryRecorder()
        let recovery = makeRecovery(
            factory: factory, onEvent: { recorder.record($0) },
            onFailure: { _ in XCTFail("主动关闭不能报告恢复失败") },
            delay: { _ in
                waiting.fulfill()
                await gate.wait()
            })
        try await recovery.start()
        try XCTUnwrap(factory.sessions.first).fail(code: -3821)
        await fulfillment(of: [waiting], timeout: 1)
        recovery.cancel()
        await gate.release()
        await recovery.stop()
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertFalse(recorder.events.contains(.resumed))
    }

    func testCancelDuringReplacementStartDrainsIt() async throws {
        let starting = expectation(description: "恢复中的 start")
        let gate = CaptureRecoveryGate()
        let factory = CaptureRecoveryFactory(onStart: { index, _ in
            if index > 0 {
                starting.fulfill()
                await gate.wait()
            }
        })
        let recorder = CaptureRecoveryRecorder()
        let recovery = makeRecovery(
            factory: factory, onEvent: { recorder.record($0) },
            onFailure: { _ in XCTFail("主动关闭不能报告恢复失败") })
        try await recovery.start()
        try XCTUnwrap(factory.sessions.first).fail(code: -3821)
        await fulfillment(of: [starting], timeout: 1)
        recovery.cancel()
        await gate.release()
        await recovery.stop()
        XCTAssertTrue(factory.sessions.allSatisfy(\.wasCancelled))
        XCTAssertFalse(recorder.events.contains(.resumed))
    }

    func testLateStoppedCallbackCannotStopReplacement() async throws {
        let resumed = expectation(description: "采集恢复")
        let recorder = CaptureRecoveryRecorder()
        let factory = CaptureRecoveryFactory()
        let recovery = makeRecovery(
            factory: factory,
            onEvent: {
                recorder.record($0)
                if $0 == .resumed { resumed.fulfill() }
            }, onFailure: { _ in XCTFail("旧采集回调不能影响当前采集") })
        try await recovery.start()
        let first = try XCTUnwrap(factory.sessions.first)
        first.fail(code: -3821)
        await fulfillment(of: [resumed], timeout: 1)
        let events = recorder.events
        first.fail(code: -3817)
        first.fail(code: -3821)
        XCTAssertEqual(recorder.events, events)
        XCTAssertEqual(factory.sessions.count, 2)
        XCTAssertFalse(try XCTUnwrap(factory.sessions.last).wasCancelled)
        await recovery.stop()
    }

    func testPermissionFailureWhileRestartingIsTerminal() async throws {
        let failed = expectation(description: "权限失效后停止")
        let factory = CaptureRecoveryFactory(onStart: { index, _ in
            if index > 0 { throw NSError(domain: SCStreamErrorDomain, code: -3801) }
        })
        let recovery = makeRecovery(factory: factory, onFailure: { _ in failed.fulfill() })
        try await recovery.start()
        try XCTUnwrap(factory.sessions.first).fail(code: -3821)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(factory.sessions.count, 2)
        await recovery.stop()
    }

    func testCadenceUpdateFailureDoesNotTerminateCaptureOrBlockLaterRecovery() async throws {
        let resumed = expectation(description: "配置更新失败后仍能恢复系统停止")
        let unexpectedFailure = expectation(description: "配置更新失败不能终止采集")
        unexpectedFailure.isInverted = true
        let factory = CaptureRecoveryFactory()
        let recovery = makeRecovery(
            factory: factory, onEvent: { if $0 == .resumed { resumed.fulfill() } },
            onFailure: { _ in unexpectedFailure.fulfill() })
        try await recovery.start()
        let first = try XCTUnwrap(factory.sessions.first)
        first.fail(HostScreenCaptureError.configurationUpdateFailed("synthetic"))
        first.fail(code: -3821)
        await fulfillment(of: [resumed, unexpectedFailure], timeout: 0.3)
        XCTAssertEqual(factory.sessions.count, 2)
        await recovery.stop()
    }

    func testSystemStoppedStreamRebuildsCaptureOnSameDisplay() async throws {
        let restarted = expectation(description: "采集恢复")
        let factory = CaptureRecoveryFactory()
        let recovery = makeRecovery(
            factory: factory, onEvent: { if $0 == .resumed { restarted.fulfill() } })
        try await recovery.start()
        let first = try XCTUnwrap(factory.sessions.first)
        first.fail(code: -3821)
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(factory.sessions.count, 2)
        XCTAssertEqual(factory.requiredDisplays.compactMap { $0 }, [42])
        XCTAssertTrue(first.wasCancelled)
        await recovery.stop()
    }

    private func makeRecovery(
        factory: CaptureRecoveryFactory,
        onEvent: @escaping @Sendable (HostCaptureRecoveryEvent) -> Void = { _ in },
        onFailure: @escaping @Sendable (Error) -> Void = { _ in },
        delay: @escaping HostCaptureRecovery.Delay = { _ in },
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> HostCaptureRecovery {
        HostCaptureRecovery(
            configuration: HostCaptureConfiguration(
                displayIndex: 0, width: 256, height: 144, framesPerSecond: 30),
            factory: { factory.make(requiredDisplay: $0, onStopped: $1) }, onEvent: onEvent,
            onFailure: onFailure, delay: delay, now: now)
    }
}

private final class CaptureRecoveryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CaptureRecoverySession] = []
    private var displays: [UInt32?] = []
    var sessions: [CaptureRecoverySession] { lock.withLock { values } }
    var requiredDisplays: [UInt32?] { lock.withLock { displays } }
    private let onStart: @Sendable (Int, CaptureRecoverySession) async throws -> Void

    init(
        onStart: @escaping @Sendable (Int, CaptureRecoverySession) async throws -> Void = { _, _ in
        }
    ) { self.onStart = onStart }

    func make(requiredDisplay: UInt32?, onStopped: @escaping @Sendable (Error) -> Void)
        -> any HostCaptureSession
    {
        lock.withLock {
            let index = values.count
            let session = CaptureRecoverySession(
                onStopped: onStopped,
                onStart: { [onStart] session in try await onStart(index, session) })
            values.append(session)
            displays.append(requiredDisplay)
            return session
        }
    }
}

private final class CaptureRecoverySession: HostCaptureSession, @unchecked Sendable {
    let capturedDisplayID: UInt32? = 42
    private let lock = NSLock()
    private var cancelled = false
    private let onStopped: @Sendable (Error) -> Void
    private let onStart: @Sendable (CaptureRecoverySession) async throws -> Void
    var wasCancelled: Bool { lock.withLock { cancelled } }

    init(
        onStopped: @escaping @Sendable (Error) -> Void,
        onStart: @escaping @Sendable (CaptureRecoverySession) async throws -> Void
    ) {
        self.onStopped = onStopped
        self.onStart = onStart
    }

    func start(configuration: HostCaptureConfiguration) async throws {
        if wasCancelled { throw CancellationError() }
        try await onStart(self)
        if wasCancelled { throw CancellationError() }
    }

    func cancel() { lock.withLock { cancelled = true } }
    func stop() async { cancel() }
    func fail(code: Int) { onStopped(NSError(domain: SCStreamErrorDomain, code: code)) }
    func fail(_ error: Error) { onStopped(error) }
}

private final class CaptureRecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [HostCaptureRecoveryEvent] = []
    private var recordedDelays: [UInt64] = []
    var events: [HostCaptureRecoveryEvent] { lock.withLock { recordedEvents } }
    var delays: [UInt64] { lock.withLock { recordedDelays } }
    func record(_ event: HostCaptureRecoveryEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
    func recordDelay(_ value: UInt64) { lock.withLock { recordedDelays.append(value) } }
}

private actor CaptureRecoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class CaptureRecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 1
    var value: UInt64 { lock.withLock { time } }
    func advance() { lock.withLock { time += 60_000_000_000 } }
}

private final class LiveCaptureRecoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let frames: [XCTestExpectation]
    private var captures: [(HostScreenCaptureAdapter, @Sendable (Error) -> Void)] = []
    private var firstFrames: [Int: CMTime] = [:]
    var sessions: [(HostScreenCaptureAdapter, @Sendable (Error) -> Void)] {
        lock.withLock { captures }
    }
    var timestamps: [CMTime] {
        lock.withLock { firstFrames.sorted { $0.key < $1.key }.map(\.value) }
    }

    init(frames: [XCTestExpectation]) { self.frames = frames }

    func make(displayID: UInt32?, onStopped: @escaping @Sendable (Error) -> Void)
        -> any HostCaptureSession
    {
        let index = lock.withLock { captures.count }
        let capture = HostScreenCaptureAdapter(
            onFrame: { [weak self] frame in self?.received(frame, index: index) },
            onSample: { _ in }, onDrop: { _ in }, onCadence: { _ in }, pressureProvider: { .clear },
            onError: { onStopped($0) }, requiredDisplayID: displayID, onStreamStopped: onStopped)
        lock.withLock { captures.append((capture, onStopped)) }
        return capture
    }

    private func received(_ frame: HostCapturedFrame, index: Int) {
        let first = lock.withLock {
            guard firstFrames[index] == nil else { return false }
            firstFrames[index] = frame.presentationTime
            return true
        }
        if first, frames.indices.contains(index) { frames[index].fulfill() }
    }
}
