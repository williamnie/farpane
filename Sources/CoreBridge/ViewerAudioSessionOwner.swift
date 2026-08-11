import Foundation

public enum ViewerAudioSessionPhase: Equatable, Sendable {
    case disabled
    case awaitingRemotePermission
    case receiving
    case deniedByRemote
    case revokedByRemote
    case ended
}

public struct ViewerAudioSessionSnapshot: Equatable, Sendable {
    public let receiveAudio: Bool
    public let connectionEpoch: UInt64?
    public let phase: ViewerAudioSessionPhase
}

/// Owns one immutable Viewer audio opt-in across the typed permission events
/// emitted by one Core connection. A first positive epoch is pinned; stale or
/// replacement-connection events fail closed and product code must create a
/// new owner for recovery.
public final class ViewerAudioSessionOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let receiveAudio: Bool
    private var connectionEpoch: UInt64?
    private var phase: ViewerAudioSessionPhase

    public init(receiveAudio: Bool) {
        self.receiveAudio = receiveAudio
        phase = receiveAudio ? .awaitingRemotePermission : .disabled
    }

    public func snapshot() -> ViewerAudioSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ViewerAudioSessionSnapshot(
            receiveAudio: receiveAudio,
            connectionEpoch: connectionEpoch,
            phase: phase
        )
    }

    @discardableResult
    public func observe(_ event: CoreRemotePermissionEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard
            receiveAudio,
            phase != .ended,
            event.permission == .audio,
            event.connectionEpoch > 0
        else { return false }
        if let connectionEpoch {
            guard connectionEpoch == event.connectionEpoch else { return false }
        } else {
            connectionEpoch = event.connectionEpoch
        }
        let next: ViewerAudioSessionPhase
        if event.enabled {
            next = .receiving
        } else if phase == .receiving || phase == .revokedByRemote {
            next = .revokedByRemote
        } else {
            next = .deniedByRemote
        }
        guard phase != next else { return false }
        phase = next
        return true
    }

    public func stop() {
        lock.lock()
        phase = .ended
        lock.unlock()
    }
}

public struct ViewerAudioSessionPresentation: Equatable, Sendable {
    public let statusText: String
    public let statusIsError: Bool
}

public enum ViewerAudioSessionPresentationPolicy {
    public static func project(
        _ snapshot: ViewerAudioSessionSnapshot
    ) -> ViewerAudioSessionPresentation {
        switch snapshot.phase {
        case .disabled:
            return ViewerAudioSessionPresentation(
                statusText: "音频：本次未开启",
                statusIsError: false
            )
        case .awaitingRemotePermission:
            return ViewerAudioSessionPresentation(
                statusText: "音频：等待远端授权",
                statusIsError: false
            )
        case .receiving:
            return ViewerAudioSessionPresentation(
                statusText: "音频：正在接收",
                statusIsError: false
            )
        case .deniedByRemote:
            return ViewerAudioSessionPresentation(
                statusText: "音频：远端未授权",
                statusIsError: true
            )
        case .revokedByRemote:
            return ViewerAudioSessionPresentation(
                statusText: "音频：远端已撤销",
                statusIsError: true
            )
        case .ended:
            return ViewerAudioSessionPresentation(
                statusText: "音频：已停止",
                statusIsError: false
            )
        }
    }
}
