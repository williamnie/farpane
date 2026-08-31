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
        _ resumePending: Bool,
        _ message: String?,
        _ isError: Bool,
        _ didActivate: Bool
    ) -> Void

    var onStatusChange: StatusHandler?

    private let eventDispatcher: ExclusiveKeyboardEventDispatcher
    private let lock = NSLock()
    private var stateMachine = ExclusiveKeyboardStateMachine()
    private var focusIntent = ExclusiveKeyboardFocusIntent()
    private var remoteHeldKeys: [UInt16: CoreKey] = [:]
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var displaySelectionInputQuiesced = false

    init(
        sendKey: @escaping @Sendable (CoreKeyEvent) -> Int32,
        recordInputResult: @escaping @Sendable (String, Int32) -> Void
    ) {
        eventDispatcher = ExclusiveKeyboardEventDispatcher(
            send: sendKey,
            recordResult: recordInputResult
        )
    }

    deinit {
        disable(message: nil, isError: false, notify: false)
    }

    var isActive: Bool {
        lock.withLock { stateMachine.state != .inactive }
    }

    func toggle() {
        enum Action {
            case disableActive
            case cancelPending
            case request
        }
        let action = lock.withLock { () -> Action in
            if stateMachine.state != .inactive {
                return .disableActive
            }
            if focusIntent.shouldResume {
                focusIntent.cancel()
                return .cancelPending
            }
            focusIntent.request()
            return .request
        }
        switch action {
        case .disableActive:
            disable(message: nil, isError: false)
        case .cancelPending:
            notifyStatus(
                active: false,
                resumePending: false,
                message: "已取消键盘独占自动恢复",
                isError: false,
                didActivate: false
            )
        case .request:
            resumeIfRequested()
        }
    }

    func reconcileFocus(applicationActive: Bool, windowKey: Bool) {
        if !applicationActive {
            setApplicationActive(false)
            setWindowKey(windowKey)
        } else if !windowKey {
            setWindowKey(false)
            setApplicationActive(true)
        } else {
            setApplicationActive(true)
            setWindowKey(true)
        }
    }

    func setApplicationActive(_ active: Bool) {
        setSuspended(
            !active,
            for: .applicationInactive,
            message: "应用失去焦点，已暂时释放键盘；返回后自动恢复独占"
        )
    }

    func setWindowKey(_ isKey: Bool) {
        setSuspended(
            !isKey,
            for: .windowNotKey,
            message: "窗口失去焦点，已暂时释放键盘；返回后自动恢复独占"
        )
    }

    func setControlOverlayVisible(_ visible: Bool) {
        setSuspended(
            visible,
            for: .controlOverlayVisible,
            message: "本地控制菜单已打开，键盘独占已暂时释放"
        )
    }

    func resumeIfRequested() {
        guard lock.withLock({
            !displaySelectionInputQuiesced
                && focusIntent.canResume
                && stateMachine.state == .inactive
        }) else {
            return
        }
        guard hasRequiredPermissions(prompt: true) else {
            lock.withLock { focusIntent.cancel() }
            notifyStatus(
                active: false,
                resumePending: false,
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
                resumePending: false,
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
            resumePending: false,
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
        let resources = lock.withLock { () -> (
            resumePending: Bool,
            shouldNotify: Bool,
            tap: CFMachPort?,
            source: CFRunLoopSource?,
            runLoop: CFRunLoop?,
            keys: [CoreKey]
        ) in
            let intentWasRequested = focusIntent.shouldResume
            if !preserveIntent { focusIntent.cancel() }
            let active = stateMachine.state != .inactive || tap != nil
            let resources = (
                resumePending: focusIntent.shouldResume,
                shouldNotify: active || (!preserveIntent && intentWasRequested),
                tap: tap,
                source: tapSource,
                runLoop: tapRunLoop,
                keys: Array(remoteHeldKeys.values)
            )
            tap = nil
            tapSource = nil
            tapRunLoop = nil
            remoteHeldKeys.removeAll()
            stateMachine.deactivate()
            return resources
        }
        releaseRemoteKeys(resources.keys)
        if let tap = resources.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = resources.source { CFRunLoopSourceInvalidate(source) }
        if let runLoop = resources.runLoop { CFRunLoopStop(runLoop) }
        if notify, resources.shouldNotify {
            notifyStatus(
                active: false,
                resumePending: resources.resumePending,
                message: message,
                isError: isError,
                didActivate: false
            )
        }
    }

    func setDisplaySelectionInputQuiesced(_ quiesced: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard displaySelectionInputQuiesced != quiesced else { return false }
            displaySelectionInputQuiesced = quiesced
            return true
        }
        guard changed else { return }
        setSuspended(
            quiesced,
            for: .displaySelection,
            message: "正在切换显示器，已暂时释放键盘独占"
        )
    }

    private func setSuspended(
        _ suspended: Bool,
        for reason: ExclusiveKeyboardSuspensionReason,
        message: String
    ) {
        let changed = lock.withLock {
            focusIntent.setSuspended(
                suspended,
                for: reason,
                state: stateMachine.state
            )
        }
        guard changed else { return }
        if suspended {
            disable(
                message: message,
                isError: false,
                preserveIntent: true
            )
        } else {
            resumeIfRequested()
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
                resumePending: false,
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
        eventDispatcher.enqueue(event)
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
        resumePending: Bool,
        message: String?,
        isError: Bool,
        didActivate: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(active, resumePending, message, isError, didActivate)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
