import AppKit
import CoreBridge
import MetalKit
import ViewerInput

final class ViewerMetalView: MTKView {
    var sendPointer: ((CorePointerEvent) -> Int32)?
    var sendKey: ((CoreKeyEvent) -> Int32)?
    var sendText: ((String) -> Int32)?
    var recordInputResult: ((String, Int32) -> Void)?
    var onWindowResignKey: (() -> Void)?

    private var trackingAreaReference: NSTrackingArea?
    private var remoteSize = CGSize.zero
    private var heldButtons: CorePointerButtons = []
    private var heldKeys: [UInt16: CoreKey] = [:]
    private var lastRemotePoint: RemotePoint?
    private var resignObserver: NSObjectProtocol?
    private var pendingMove: CorePointerEvent?
    private var moveFlushScheduled = false
    private var interpretingEvent: NSEvent?
    private var markedTextStorage = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var keyboardInputEnabled = true

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func updateRemoteSize(width: Int, height: Int) {
        remoteSize = CGSize(width: max(0, width), height: max(0, height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = window.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.releaseAllInput()
                self?.onWindowResignKey?()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseMoved(with event: NSEvent) { sendMove(event, clamp: false) }
    override func mouseDragged(with event: NSEvent) { sendMove(event, clamp: true) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event, clamp: true) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event, clamp: true) }

    override func mouseDown(with event: NSEvent) { sendButton(.left, down: true, event: event) }
    override func mouseUp(with event: NSEvent) { sendButton(.left, down: false, event: event) }
    override func rightMouseDown(with event: NSEvent) { sendButton(.right, down: true, event: event) }
    override func rightMouseUp(with event: NSEvent) { sendButton(.right, down: false, event: event) }
    override func otherMouseDown(with event: NSEvent) { sendButton(.middle, down: true, event: event) }
    override func otherMouseUp(with event: NSEvent) { sendButton(.middle, down: false, event: event) }

    override func scrollWheel(with event: NSEvent) {
        guard map(event, clamp: false) != nil else { return }
        guard let delta = ScrollDeltaMapper.map(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas
        ) else { return }
        flushPendingMove()
        send(
            CorePointerEvent(
                kind: delta.kind,
                scrollX: delta.x,
                scrollY: delta.y,
                modifiers: MacKeyMapper.modifiers(from: event.modifierFlags)
            ),
            category: "scroll"
        )
    }

    override func keyDown(with event: NSEvent) {
        guard keyboardInputEnabled else { return }
        let modifiers = MacKeyMapper.modifiers(from: event.modifierFlags)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            if event.isARepeat {
                sendKeyboardPress(event)
            } else {
                sendKeyboard(event, isDown: true)
            }
            return
        }
        interpretingEvent = event
        interpretKeyEvents([event])
        interpretingEvent = nil
    }
    override func keyUp(with event: NSEvent) {
        guard keyboardInputEnabled else { return }
        guard heldKeys[event.keyCode] != nil else { return }
        sendKeyboard(event, isDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard keyboardInputEnabled else { return }
        guard let isDown = MacKeyMapper.modifierIsDown(keyCode: event.keyCode, flags: event.modifierFlags),
              let key = MacKeyMapper.key(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: nil
              ) else { return }
        var modifiers = MacKeyMapper.modifiers(from: event.modifierFlags)
        switch key {
        case .special(.shift): modifiers.remove(.shift)
        case .special(.control): modifiers.remove(.control)
        case .special(.option): modifiers.remove(.option)
        case .special(.command): modifiers.remove(.command)
        default: break
        }
        sendKeyEvent(keyCode: event.keyCode, key: key, isDown: isDown, modifiers: modifiers)
    }

    private func sendMove(_ event: NSEvent, clamp: Bool) {
        guard let point = map(event, clamp: clamp) else { return }
        lastRemotePoint = point
        pendingMove = CorePointerEvent(
            kind: .move,
            x: point.x,
            y: point.y,
            buttons: heldButtons,
            modifiers: MacKeyMapper.modifiers(from: event.modifierFlags)
        )
        guard !moveFlushScheduled else { return }
        moveFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.flushPendingMove()
        }
    }

    private func sendButton(_ button: CorePointerButtons, down: Bool, event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = map(event, clamp: down || !heldButtons.isEmpty) else { return }
        flushPendingMove()
        lastRemotePoint = point
        if down { heldButtons.insert(button) }
        send(
            CorePointerEvent(
                kind: down ? .down : .up,
                x: point.x,
                y: point.y,
                buttons: button,
                modifiers: MacKeyMapper.modifiers(from: event.modifierFlags)
            ),
            category: down ? "button-down" : "button-up"
        )
        if !down { heldButtons.remove(button) }
    }

    private func sendKeyboard(_ event: NSEvent, isDown: Bool) {
        guard let key = MacKeyMapper.key(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else { return }
        sendKeyEvent(
            keyCode: event.keyCode,
            key: key,
            isDown: isDown,
            modifiers: MacKeyMapper.modifiers(from: event.modifierFlags)
        )
    }

    private func sendKeyboardPress(_ event: NSEvent) {
        guard let key = MacKeyMapper.key(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else { return }
        sendKeyPress(key, modifiers: MacKeyMapper.modifiers(from: event.modifierFlags))
    }

    private func sendKeyPress(_ key: CoreKey, modifiers: CoreInputModifiers) {
        let downStatus = sendKey?(CoreKeyEvent(key: key, isDown: true, modifiers: modifiers)) ?? -3
        recordInputResult?("key-down", downStatus)
        let upStatus = sendKey?(CoreKeyEvent(key: key, isDown: false, modifiers: modifiers)) ?? -3
        recordInputResult?("key-up", upStatus)
    }

    private func sendKeyEvent(
        keyCode: UInt16,
        key: CoreKey,
        isDown: Bool,
        modifiers: CoreInputModifiers
    ) {
        if isDown { heldKeys[keyCode] = key } else { heldKeys.removeValue(forKey: keyCode) }
        let status = sendKey?(CoreKeyEvent(key: key, isDown: isDown, modifiers: modifiers)) ?? -3
        recordInputResult?(isDown ? "key-down" : "key-up", status)
    }

    private func send(_ event: CorePointerEvent, category: String) {
        let status = sendPointer?(event) ?? -3
        recordInputResult?(category, status)
    }

    private func flushPendingMove() {
        moveFlushScheduled = false
        guard let event = pendingMove else { return }
        pendingMove = nil
        send(event, category: "pointer-move")
    }

    private func map(_ event: NSEvent, clamp: Bool) -> RemotePoint? {
        let point = convert(event.locationInWindow, from: nil)
        let mapper = AspectFitCoordinateMapper(
            remoteSize: remoteSize,
            viewSizePoints: bounds.size,
            backingScale: window?.backingScaleFactor ?? 1
        )
        return mapper.map(pointInViewPoints: point, clampToContent: clamp)
    }

    func setKeyboardInputEnabled(_ enabled: Bool) {
        if keyboardInputEnabled, !enabled { releaseAllKeyboardInput() }
        keyboardInputEnabled = enabled
    }

    func releaseAllKeyboardInput() {
        markedTextStorage = ""
        markedSelection = NSRange(location: 0, length: 0)
        let keysToRelease = heldKeys
        heldKeys.removeAll()
        for (_, key) in keysToRelease {
            let status = sendKey?(CoreKeyEvent(key: key, isDown: false)) ?? -3
            recordInputResult?("key-up", status)
        }
    }

    func releaseAllInput() {
        flushPendingMove()
        releaseAllKeyboardInput()
        if let point = lastRemotePoint {
            for button: CorePointerButtons in [.left, .right, .middle] where heldButtons.contains(button) {
                send(
                    CorePointerEvent(kind: .up, x: point.x, y: point.y, buttons: button),
                    category: "button-up"
                )
            }
        }
        heldButtons = []
    }
}

extension ViewerMetalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard keyboardInputEnabled else { return }
        guard let text = plainText(string), !text.isEmpty else { return }
        markedTextStorage = ""
        markedSelection = NSRange(location: 0, length: 0)
        let status = sendText?(text) ?? -3
        for _ in text.unicodeScalars {
            recordInputResult?("key-down", status)
            recordInputResult?("key-up", status)
        }
    }

    override func doCommand(by selector: Selector) {
        guard keyboardInputEnabled else { return }
        let special: CoreSpecialKey?
        switch NSStringFromSelector(selector) {
        case "cancelOperation:": special = .escape
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:": special = .return
        case "insertTab:", "insertBacktab:": special = .tab
        case "deleteBackward:": special = .backspace
        case "deleteForward:": special = .deleteForward
        case "moveLeft:": special = .left
        case "moveRight:": special = .right
        case "moveUp:": special = .up
        case "moveDown:": special = .down
        case "moveToBeginningOfLine:", "moveToBeginningOfDocument:": special = .home
        case "moveToEndOfLine:", "moveToEndOfDocument:": special = .end
        case "pageUp:": special = .pageUp
        case "pageDown:": special = .pageDown
        default: special = nil
        }
        guard let special else { return }
        let modifiers = interpretingEvent.map {
            MacKeyMapper.modifiers(from: $0.modifierFlags)
        } ?? []
        sendKeyPress(.special(special), modifiers: modifiers)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedTextStorage = plainText(string) ?? ""
        markedSelection = selectedRange
    }

    func unmarkText() {
        markedTextStorage = ""
        markedSelection = NSRange(location: 0, length: 0)
    }

    func selectedRange() -> NSRange { markedSelection }

    func markedRange() -> NSRange {
        markedTextStorage.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedTextStorage as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedTextStorage.isEmpty }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        let full = markedTextStorage as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= full.length else { return nil }
        actualRange?.pointee = range
        return NSAttributedString(string: full.substring(with: range))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let localRect = NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 24)
        guard let window else { return localRect }
        return window.convertToScreen(convert(localRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    private func plainText(_ value: Any) -> String? {
        if let value = value as? NSAttributedString { return value.string }
        return value as? String
    }
}
