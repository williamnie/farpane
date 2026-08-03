import ApplicationServices
import CoreBridge
import CoreGraphics
import Foundation
import ViewerInput

private let exclusiveKeyboardTapCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<ExclusiveKeyboardController>.fromOpaque(context).takeUnretainedValue()
    return controller.handleTap(type: type, event: event)
}

private enum ExclusiveTapOutcome {
    case passThrough
    case suppressed
    case beganExit
    case completedExit
}

final class ExclusiveKeyboardController: @unchecked Sendable {
    typealias StatusHandler = (
        _ active: Bool,
        _ message: String?,
        _ isError: Bool,
        _ didActivate: Bool
    ) -> Void

    var onStatusChange: StatusHandler?

    private let sendKey: (CoreKeyEvent) -> Int32
    private let recordInputResult: (String, Int32) -> Void
    private let lock = NSLock()
    private var stateMachine = ExclusiveKeyboardStateMachine()
    private var focusIntent = ExclusiveKeyboardFocusIntent()
    private var remoteHeldKeys: [UInt16: CoreKey] = [:]
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?

    init(
        sendKey: @escaping (CoreKeyEvent) -> Int32,
        recordInputResult: @escaping (String, Int32) -> Void
    ) {
        self.sendKey = sendKey
        self.recordInputResult = recordInputResult
    }

    deinit {
        disable(message: nil, isError: false, notify: false)
    }

    var isActive: Bool {
        lock.withLock { stateMachine.state != .inactive }
    }

    func toggle() {
        let shouldDisable = lock.withLock { () -> Bool in
            if stateMachine.state != .inactive {
                focusIntent.cancel()
                return true
            }
            focusIntent.request()
            return false
        }
        if shouldDisable {
            disable(message: nil, isError: false)
        } else {
            resumeIfRequested()
        }
    }

    func suspend(message: String) {
        lock.withLock {
            focusIntent.prepareForFocusLoss(state: stateMachine.state)
        }
        disable(message: message, isError: false, preserveIntent: true)
    }

    func resumeIfRequested() {
        guard lock.withLock({ focusIntent.shouldResume && stateMachine.state == .inactive }) else {
            return
        }
        guard hasRequiredPermissions(prompt: true) else {
            lock.withLock { focusIntent.cancel() }
            notifyStatus(
                active: false,
                message: "请在系统设置授予辅助功能和输入监控权限，然后重新点击“独占键盘”",
                isError: true,
                didActivate: false
            )
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: exclusiveKeyboardTapCallback,
            userInfo: context
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            lock.withLock { focusIntent.cancel() }
            notifyStatus(
                active: false,
                message: "无法建立键盘独占，请检查系统权限后重试",
                isError: true,
                didActivate: false
            )
            return
        }

        lock.withLock {
            stateMachine.activate()
            remoteHeldKeys.removeAll()
            self.tap = tap
            tapSource = source
        }
        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.lock.withLock { self.tapRunLoop = runLoop }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            self.lock.withLock {
                if self.tapRunLoop === runLoop { self.tapRunLoop = nil }
            }
        }
        thread.name = "io.rustdesknative.keyboard-capture"
        thread.qualityOfService = .userInteractive
        thread.start()
        notifyStatus(
            active: true,
            message: "键盘独占中 · ⌃⌥⇧Esc 退出",
            isError: false,
            didActivate: true
        )
    }

    func disable(
        message: String?,
        isError: Bool,
        notify: Bool = true,
        preserveIntent: Bool = false
    ) {
        let resources = lock.withLock { () -> (Bool, CFMachPort?, CFRunLoopSource?, CFRunLoop?, [CoreKey]) in
            if !preserveIntent { focusIntent.cancel() }
            let active = stateMachine.state != .inactive || tap != nil
            let resources = (active, tap, tapSource, tapRunLoop, Array(remoteHeldKeys.values))
            tap = nil
            tapSource = nil
            tapRunLoop = nil
            remoteHeldKeys.removeAll()
            stateMachine.deactivate()
            return resources
        }
        guard resources.0 else { return }
        releaseRemoteKeys(resources.4)
        if let tap = resources.1 {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = resources.2 { CFRunLoopSourceInvalidate(source) }
        if let runLoop = resources.3 { CFRunLoopStop(runLoop) }
        if notify {
            notifyStatus(active: false, message: message, isError: isError, didActivate: false)
        }
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            failOpenFromTap()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = MacKeyMapper.modifiers(from: event.flags)
        let repeatEvent = type == .keyDown
            && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let isDown: Bool
        switch type {
        case .keyDown: isDown = true
        case .keyUp: isDown = false
        case .flagsChanged:
            guard let flagsSayDown = MacKeyMapper.modifierIsDown(
                keyCode: keyCode,
                flags: event.flags
            ) else { return Unmanaged.passUnretained(event) }
            let wasHeld = lock.withLock { stateMachine.isHeld(keyCode: keyCode) }
            isDown = wasHeld ? false : flagsSayDown
        default: return Unmanaged.passUnretained(event)
        }

        let outcome = lock.withLock { () -> ExclusiveTapOutcome in
            let decision = stateMachine.handle(
                keyCode: keyCode,
                isDown: isDown,
                modifiers: modifiers,
                isRepeat: repeatEvent
            )
            guard decision.suppressLocally else { return .passThrough }
            if decision.beganExit {
                let keys = Array(remoteHeldKeys.values)
                remoteHeldKeys.removeAll()
                releaseRemoteKeys(keys)
                return .beganExit
            }
            if decision.completedExit { return .completedExit }
            guard decision.forwardRemotely else { return .suppressed }

            let mappedKey = remoteHeldKeys[keyCode]
                ?? MacKeyMapper.physicalKeyFromHardwareCode(keyCode)
            guard let key = mappedKey else {
                // Unsupported hardware/media keys remain local rather than being silently lost.
                return .passThrough
            }

            if repeatEvent {
                sendAndRecord(CoreKeyEvent(key: key, isDown: true))
                sendAndRecord(CoreKeyEvent(key: key, isDown: false))
            } else {
                if isDown { remoteHeldKeys[keyCode] = key }
                else { remoteHeldKeys.removeValue(forKey: keyCode) }
                sendAndRecord(CoreKeyEvent(key: key, isDown: isDown))
            }
            return .suppressed
        }

        switch outcome {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .beganExit:
            notifyStatus(
                active: true,
                message: "松开 ⌃⌥⇧Esc 以退出键盘独占",
                isError: false,
                didActivate: false
            )
            return nil
        case .completedExit:
            DispatchQueue.main.async { [weak self] in
                self?.disable(message: "已退出键盘独占", isError: false)
            }
            return nil
        case .suppressed:
            return nil
        }
    }

    private func hasRequiredPermissions(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let accessibility = AXIsProcessTrustedWithOptions(options)
        var listening = CGPreflightListenEventAccess()
        if prompt, !listening {
            listening = CGRequestListenEventAccess()
        }
        return accessibility && listening
    }

    private func sendAndRecord(_ event: CoreKeyEvent) {
        let status = sendKey(event)
        recordInputResult(event.isDown ? "key-down" : "key-up", status)
    }

    private func releaseAllCapturedKeys() {
        let keys = lock.withLock { () -> [CoreKey] in
            let keys = Array(remoteHeldKeys.values)
            remoteHeldKeys.removeAll()
            return keys
        }
        releaseRemoteKeys(keys)
    }

    private func releaseRemoteKeys(_ keys: [CoreKey]) {
        for key in keys {
            sendAndRecord(CoreKeyEvent(key: key, isDown: false))
        }
    }

    private func failOpenFromTap() {
        releaseAllCapturedKeys()
        DispatchQueue.main.async { [weak self] in
            self?.disable(
                message: "键盘独占已被系统停用，已恢复本地输入",
                isError: true
            )
        }
    }

    private func notifyStatus(
        active: Bool,
        message: String?,
        isError: Bool,
        didActivate: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(active, message, isError, didActivate)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
