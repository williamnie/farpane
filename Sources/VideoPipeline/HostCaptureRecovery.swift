import Foundation
import ScreenCaptureKit

protocol HostCaptureSession: AnyObject, Sendable {
    var capturedDisplayID: UInt32? { get }
    func start(configuration: HostCaptureConfiguration) async throws
    func cancel()
    func stop() async
}

extension HostScreenCaptureAdapter: HostCaptureSession {}

enum HostCaptureRecoveryEvent: Equatable, Sendable {
    case stopped(code: Int?)
    case retrying
    case resumed
    case exhausted
}

package struct HostCaptureRecoveryDiagnostics: Codable, Equatable, Sendable {
    var stoppedStreams = 0
    var attempts = 0
    var restartedStreams = 0
    var exhausted = 0
    var lastErrorCode: Int?
}

/// 仅替换屏幕采集会话，编码器与媒体路由的时间基准由外层继续持有。
final class HostCaptureRecovery: @unchecked Sendable {
    typealias Factory =
        @Sendable (UInt32?, @escaping @Sendable (Error) -> Void) -> any HostCaptureSession
    typealias Delay = @Sendable (UInt64) async throws -> Void

    private let configuration: HostCaptureConfiguration
    private let factory: Factory
    private let beforeRestart: @Sendable () -> Void
    private let onEvent: @Sendable (HostCaptureRecoveryEvent) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let delay: Delay
    private let now: @Sendable () -> UInt64
    private let lock = NSLock()
    private var capture: (any HostCaptureSession)?
    private var cancelled = false
    private var generation: UInt64 = 0
    private var pendingRecovery = false
    private var recoveryTask: Task<Void, Never>?
    private var attemptTimes: [UInt64] = []

    init(
        configuration: HostCaptureConfiguration, factory: @escaping Factory,
        beforeRestart: @escaping @Sendable () -> Void = {},
        onEvent: @escaping @Sendable (HostCaptureRecoveryEvent) -> Void = { _ in },
        onFailure: @escaping @Sendable (Error) -> Void,
        delay: @escaping Delay = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.configuration = configuration
        self.factory = factory
        self.beforeRestart = beforeRestart
        self.onEvent = onEvent
        self.onFailure = onFailure
        self.delay = delay
        self.now = now
    }

    func start() async throws {
        let capture = try lock.withLock {
            guard !cancelled, generation == 0 else { throw CancellationError() }
            generation = 1
            let capture = makeCapture(displayID: nil, generation: 1)
            self.capture = capture
            return capture
        }
        do { try await capture.start(configuration: configuration) } catch {
            // 系统可能在 startCapture 返回之前就发出停止回调；恢复已接管时不再终止路由。
            guard lock.withLock({ !cancelled && (pendingRecovery || generation > 1) }) else {
                throw error
            }
        }
    }

    func cancel() {
        let capture = lock.withLock {
            cancelled = true
            recoveryTask?.cancel()
            return self.capture
        }
        capture?.cancel()
    }

    func stop() async {
        cancel()
        let (capture, task) = lock.withLock { (self.capture, recoveryTask) }
        await task?.value
        await capture?.stop()
    }

    private func makeCapture(displayID: UInt32?, generation: UInt64) -> any HostCaptureSession {
        factory(displayID) { [weak self] error in self?.streamStopped(error, generation: generation)
        }
    }

    private func streamStopped(_ error: Error, generation: UInt64) {
        // 配置更新失败时旧配置仍有效；采集适配器会在两秒后重试，不能把降帧失败升级为断流。
        if case HostScreenCaptureError.configurationUpdateFailed = error { return }
        let native = error as NSError
        let code = native.domain == SCStreamErrorDomain ? native.code : nil
        let accepted = lock.withLock {
            guard !cancelled, self.generation == generation else { return false }
            if code == -3821 {
                pendingRecovery = true
                if recoveryTask == nil {
                    recoveryTask = Task { [weak self] in await self?.recover() }
                }
            } else {
                // 用户停止、权限撤销和未知错误均保持终止语义，禁止自动重开屏幕采集。
                cancelled = true
                recoveryTask?.cancel()
            }
            return true
        }
        guard accepted else { return }
        onEvent(.stopped(code: code))
        if code != -3821 { onFailure(error) }
    }

    private func recover() async {
        while true {
            let attempt = lock.withLock { () -> (any HostCaptureSession, UInt32, UInt64, UInt64)? in
                guard !cancelled, pendingRecovery, let capture,
                    let displayID = capture.capturedDisplayID, generation < UInt64.max
                else { return nil }
                let timestamp = now()
                attemptTimes.removeAll { timestamp >= $0 && timestamp - $0 >= 60_000_000_000 }
                guard attemptTimes.count < 3 else { return nil }
                let delayNS = UInt64(1 << attemptTimes.count) * 1_000_000_000
                attemptTimes.append(timestamp)
                generation += 1
                pendingRecovery = false
                return (capture, displayID, generation, delayNS)
            }
            guard let (previous, displayID, attemptGeneration, delayNS) = attempt else {
                let exhausted = lock.withLock {
                    recoveryTask = nil
                    guard !cancelled, pendingRecovery else { return false }
                    cancelled = true
                    return true
                }
                if exhausted {
                    onEvent(.exhausted)
                    onFailure(HostScreenCaptureError.streamStopped("system recovery exhausted"))
                }
                return
            }
            previous.cancel()
            await previous.stop()
            onEvent(.retrying)
            do {
                try await delay(delayNS)
                let next = try lock.withLock {
                    guard !cancelled, !Task.isCancelled else { throw CancellationError() }
                    let next = makeCapture(displayID: displayID, generation: attemptGeneration)
                    capture = next
                    return next
                }
                // 不重建编码器，不重置 PTS；恢复后的第一帧携带 IDR/参数集。
                beforeRestart()
                try await next.start(configuration: configuration)
            } catch {
                let native = error as NSError
                if native.domain == SCStreamErrorDomain, native.code == -3821 {
                    streamStopped(error, generation: attemptGeneration)
                }
                let shouldRetry = lock.withLock { pendingRecovery && !cancelled }
                if shouldRetry { continue }
                let shouldReport = lock.withLock {
                    recoveryTask = nil
                    guard !cancelled else { return false }
                    cancelled = true
                    return true
                }
                if shouldReport { onFailure(error) }
                return
            }
            let completed = lock.withLock {
                guard !pendingRecovery else { return false }
                recoveryTask = nil
                return true
            }
            if completed {
                if lock.withLock({ !cancelled }) { onEvent(.resumed) }
                return
            }
        }
    }
}
