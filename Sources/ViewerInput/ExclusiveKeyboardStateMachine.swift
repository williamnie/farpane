import CoreBridge

public enum ExclusiveKeyboardState: Equatable {
    case inactive
    case active
    case releasingExitChord
}

public struct ExclusiveKeyboardDecision: Equatable {
    public let suppressLocally: Bool
    public let forwardRemotely: Bool
    public let beganExit: Bool
    public let completedExit: Bool

    public init(
        suppressLocally: Bool,
        forwardRemotely: Bool,
        beganExit: Bool = false,
        completedExit: Bool = false
    ) {
        self.suppressLocally = suppressLocally
        self.forwardRemotely = forwardRemotely
        self.beganExit = beganExit
        self.completedExit = completedExit
    }
}

public struct ExclusiveKeyboardStateMachine {
    public static let exitKeyCode: UInt16 = 53
    public static let exitModifiers: CoreInputModifiers = [.control, .option, .shift]

    public private(set) var state: ExclusiveKeyboardState = .inactive
    private var heldKeyCodes: Set<UInt16> = []
    private var exitChordKeyCodes: Set<UInt16> = []

    public init() {}

    public mutating func activate() {
        heldKeyCodes.removeAll()
        exitChordKeyCodes.removeAll()
        state = .active
    }

    public mutating func deactivate() {
        heldKeyCodes.removeAll()
        exitChordKeyCodes.removeAll()
        state = .inactive
    }

    public func isHeld(keyCode: UInt16) -> Bool {
        heldKeyCodes.contains(keyCode)
    }

    public mutating func handle(
        keyCode: UInt16,
        isDown: Bool,
        modifiers: CoreInputModifiers,
        isRepeat: Bool = false
    ) -> ExclusiveKeyboardDecision {
        guard state != .inactive else {
            return ExclusiveKeyboardDecision(suppressLocally: false, forwardRemotely: false)
        }

        let wasHeld = heldKeyCodes.contains(keyCode)
        if isDown, !isRepeat {
            heldKeyCodes.insert(keyCode)
        } else if !isDown {
            heldKeyCodes.remove(keyCode)
        }

        if state == .releasingExitChord {
            let completed = exitChordKeyCodes.isDisjoint(with: heldKeyCodes)
            if completed { deactivate() }
            return ExclusiveKeyboardDecision(
                suppressLocally: true,
                forwardRemotely: false,
                completedExit: completed
            )
        }

        if isDown, !isRepeat,
           keyCode == Self.exitKeyCode,
           modifiers.contains(Self.exitModifiers) {
            exitChordKeyCodes = heldKeyCodes.intersection(Self.modifierKeyCodes)
            exitChordKeyCodes.insert(Self.exitKeyCode)
            state = .releasingExitChord
            return ExclusiveKeyboardDecision(
                suppressLocally: true,
                forwardRemotely: false,
                beganExit: true
            )
        }

        let validTransition = isRepeat || (isDown ? !wasHeld : wasHeld)
        return ExclusiveKeyboardDecision(
            suppressLocally: true,
            forwardRemotely: validTransition
        )
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 60, 58, 61, 59, 62]
}

/// Remembers an explicit user request while focus is temporarily elsewhere.
/// Manual exit, an exit chord in progress, permission failure or connection
/// loss must cancel the request instead of unexpectedly grabbing the keyboard.
public enum ExclusiveKeyboardSuspensionReason: Hashable, Sendable {
    case applicationInactive
    case windowNotKey
    case controlOverlayVisible
    case displaySelection
}

public struct ExclusiveKeyboardFocusIntent {
    public private(set) var shouldResume = false
    public private(set) var suspensionReasons: Set<ExclusiveKeyboardSuspensionReason> = []

    public var canResume: Bool {
        shouldResume && suspensionReasons.isEmpty
    }

    public init() {}

    public mutating func request() {
        shouldResume = true
    }

    public mutating func cancel() {
        shouldResume = false
    }

    @discardableResult
    public mutating func setSuspended(
        _ suspended: Bool,
        for reason: ExclusiveKeyboardSuspensionReason,
        state: ExclusiveKeyboardState
    ) -> Bool {
        if suspended, state == .releasingExitChord {
            cancel()
        }
        if suspended {
            return suspensionReasons.insert(reason).inserted
        }
        return suspensionReasons.remove(reason) != nil
    }
}
