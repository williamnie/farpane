import AppKit
import CoreBridge
import CoreFoundation
import Foundation

enum HostAgentNSWorkspaceSleepWakeIngressState: Equatable, Sendable {
    case idle
    case starting
    case running
    case cancelling
    case cancelled
    case failed
}

/// Process-owned adapter from AppKit power notifications into the exact-cycle
/// recovery composition. A dedicated RunLoop keeps delivery independent of an
/// NSApplication event loop; teardown removes observers before draining the
/// accepted recovery edge.
final class HostAgentNSWorkspaceSleepWakeIngress: @unchecked Sendable {
    private let condition = NSCondition()
    private let notificationCenter: NotificationCenter
    private let willSleepNotification: Notification.Name
    private let didWakeNotification: Notification.Name
    private let deliveryOwner: HostAgentSleepWakeNotificationDeliveryOwner
    private let onFailure: @Sendable () -> Void
    private var state: HostAgentNSWorkspaceSleepWakeIngressState = .idle
    private var observerThread: Thread?
    private var observerRunLoop: CFRunLoop?
    private var observerTokens: [NSObjectProtocol] = []

    static func makeProduct(
        composition: HostAgentSleepWakeRecoveryComposition,
        lifetime: HostAgentProcessLifetime
    ) -> HostAgentNSWorkspaceSleepWakeIngress {
        HostAgentNSWorkspaceSleepWakeIngress(
            notificationCenter: NSWorkspace.shared.notificationCenter,
            willSleepNotification: NSWorkspace.willSleepNotification,
            didWakeNotification: NSWorkspace.didWakeNotification,
            deliveryOwner: HostAgentSleepWakeNotificationDeliveryOwner(
                deliverWillSleep: {
                    composition.systemWillSleep()
                },
                deliverDidWake: {
                    composition.systemDidWake()
                }
            ),
            onFailure: { [weak lifetime] in
                _ = lifetime?.requestTermination(reason: .error)
            }
        )
    }

    init(
        notificationCenter: NotificationCenter,
        willSleepNotification: Notification.Name,
        didWakeNotification: Notification.Name,
        deliveryOwner: HostAgentSleepWakeNotificationDeliveryOwner,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.willSleepNotification = willSleepNotification
        self.didWakeNotification = didWakeNotification
        self.deliveryOwner = deliveryOwner
        self.onFailure = onFailure
    }

    deinit {
        cancelAndWait()
    }

    func stateSnapshot() -> HostAgentNSWorkspaceSleepWakeIngressState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    func start() -> Bool {
        condition.lock()
        guard state == .idle else {
            condition.unlock()
            return false
        }
        state = .starting
        let thread = Thread { [weak self] in
            self?.runObserverThread()
        }
        thread.name = "com.farpane.host-agent.sleep-wake"
        observerThread = thread
        condition.unlock()

        thread.start()

        condition.lock()
        while state == .starting {
            condition.wait()
        }
        let started = state == .running
        condition.unlock()
        return started
    }

    func cancelAndWait() {
        condition.lock()
        switch state {
        case .cancelled:
            condition.unlock()
            return
        case .cancelling:
            while state == .cancelling {
                condition.wait()
            }
            condition.unlock()
            return
        case .idle, .failed:
            state = .cancelled
            condition.broadcast()
            condition.unlock()
            deliveryOwner.cancelAndWait()
            return
        case .starting, .running:
            state = .cancelling
            let tokens = observerTokens
            observerTokens.removeAll()
            let runLoop = observerRunLoop
            condition.unlock()

            removeObservers(tokens)
            deliveryOwner.cancelAndWait()
            if let runLoop {
                CFRunLoopStop(runLoop)
                CFRunLoopWakeUp(runLoop)
            }

            condition.lock()
            while state == .cancelling {
                condition.wait()
            }
            condition.unlock()
        }
    }

    private func runObserverThread() {
        autoreleasepool {
            let keepAlivePort = Port()
            RunLoop.current.add(keepAlivePort, forMode: .default)
            let runLoop = CFRunLoopGetCurrent()
            let tokens = registerObservers()

            condition.lock()
            guard state == .starting else {
                condition.unlock()
                removeObservers(tokens)
                deliveryOwner.cancelAndWait()
                condition.lock()
                state = .cancelled
                observerThread = nil
                condition.broadcast()
                condition.unlock()
                return
            }
            observerRunLoop = runLoop
            observerTokens = tokens
            state = .running
            condition.broadcast()
            condition.unlock()

            CFRunLoopRun()

            removeObservers(tokens)
            deliveryOwner.cancelAndWait()

            condition.lock()
            let exitedUnexpectedly = state == .running
            observerRunLoop = nil
            observerTokens.removeAll()
            observerThread = nil
            state = exitedUnexpectedly ? .failed : .cancelled
            condition.broadcast()
            condition.unlock()

            if exitedUnexpectedly {
                requestProcessTermination()
            }
        }
    }

    private func registerObservers() -> [NSObjectProtocol] {
        let willSleep = notificationCenter.addObserver(
            forName: willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.deliver(.willSleep)
        }
        let didWake = notificationCenter.addObserver(
            forName: didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.deliver(.didWake)
        }
        return [willSleep, didWake]
    }

    private func deliver(_ event: HostAgentSleepWakeNotificationEvent) {
        guard !deliveryOwner.deliver(event),
              case .failed = deliveryOwner.stateSnapshot()
        else {
            return
        }
        requestProcessTermination()
    }

    private func requestProcessTermination() {
        DispatchQueue.global(qos: .utility).async(execute: onFailure)
    }

    private func removeObservers(_ tokens: [NSObjectProtocol]) {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }
}
