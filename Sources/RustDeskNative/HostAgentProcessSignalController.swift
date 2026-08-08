import CoreBridge
import Darwin
import Foundation

enum HostAgentProcessSignalControllerError: Error, Equatable {
    case installationFailed
}

/// Process-owned SIGTERM/SIGINT ingress. POSIX dispositions only ignore the
/// fixed signals; all Swift work runs later on the Dispatch source queue.
final class HostAgentProcessSignalController: @unchecked Sendable {
    private struct SignalDisposition {
        let number: Int32
        var previous: sigaction
    }

    private let lock = NSLock()
    private let latch = HostAgentTerminationRequestLatch()
    private var sources: [any DispatchSourceSignal]
    private var dispositions: [SignalDisposition]
    private var cancelled = false

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.signals",
            qos: .userInitiated
        )
    ) throws {
        var installed: [SignalDisposition] = []
        do {
            installed.append(try Self.installIgnoreDisposition(for: SIGTERM))
            installed.append(try Self.installIgnoreDisposition(for: SIGINT))
        } catch {
            Self.restore(installed.reversed())
            throw HostAgentProcessSignalControllerError.installationFailed
        }

        self.dispositions = installed
        self.sources = installed.map {
            DispatchSource.makeSignalSource(signal: $0.number, queue: queue)
        }
        for source in sources {
            source.setEventHandler { [weak self] in
                _ = self?.latch.requestTermination()
            }
            source.activate()
        }
    }

    deinit {
        cancel()
    }

    /// Binds one started lifetime. A signal received during startup is
    /// delivered immediately by the latch after this method releases its lock.
    @discardableResult
    func bind(lifetime: HostAgentProcessLifetime) -> Bool {
        latch.bind {
            _ = lifetime.requestTermination(reason: .appExit)
        }
    }

    /// Cancels both activated sources and restores the process dispositions
    /// that existed before controller initialization. Idempotent.
    func cancel() {
        let sourcesToCancel: [any DispatchSourceSignal]
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        sourcesToCancel = sources
        sources.removeAll()
        lock.unlock()

        for source in sourcesToCancel {
            source.setEventHandler {}
            source.cancel()
        }
        restoreSignalDispositions()
    }

    private func restoreSignalDispositions() {
        let dispositionsToRestore: [SignalDisposition]
        lock.lock()
        dispositionsToRestore = dispositions
        dispositions.removeAll()
        lock.unlock()
        Self.restore(dispositionsToRestore.reversed())
    }

    private static func installIgnoreDisposition(
        for signalNumber: Int32
    ) throws -> SignalDisposition {
        var ignored = sigaction()
        ignored.__sigaction_u.__sa_handler = SIG_IGN
        ignored.sa_flags = 0
        guard sigemptyset(&ignored.sa_mask) == 0 else {
            throw HostAgentProcessSignalControllerError.installationFailed
        }

        var previous = sigaction()
        guard sigaction(signalNumber, &ignored, &previous) == 0 else {
            throw HostAgentProcessSignalControllerError.installationFailed
        }
        return SignalDisposition(number: signalNumber, previous: previous)
    }

    private static func restore<S: Sequence>(_ dispositions: S)
    where S.Element == SignalDisposition {
        for var disposition in dispositions {
            _ = sigaction(
                disposition.number,
                &disposition.previous,
                nil
            )
        }
    }
}
