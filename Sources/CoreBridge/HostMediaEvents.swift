import CoreBridgeShim
import Foundation

public struct HostDisplayReconfigureProvenance: Equatable, Sendable {
    public let generation: UInt64
    public let previousDisplayRevision: UInt64
    public let previousConnectionEpoch: UInt64
    public let previousCodecEpoch: UInt64

    public init(
        generation: UInt64, previousDisplayRevision: UInt64, previousConnectionEpoch: UInt64,
        previousCodecEpoch: UInt64
    ) {
        self.generation = generation
        self.previousDisplayRevision = previousDisplayRevision
        self.previousConnectionEpoch = previousConnectionEpoch
        self.previousCodecEpoch = previousCodecEpoch
    }
}

public struct HostDisplayReconfigureStarted: Equatable, Sendable {
    public let generation: UInt64
    public let displayID: UInt64
    public let previousDisplayRevision: UInt64
    public let previousConnectionEpoch: UInt64
    public let previousCodecEpoch: UInt64

    public init(
        generation: UInt64, displayID: UInt64, previousDisplayRevision: UInt64,
        previousConnectionEpoch: UInt64, previousCodecEpoch: UInt64
    ) {
        self.generation = generation
        self.displayID = displayID
        self.previousDisplayRevision = previousDisplayRevision
        self.previousConnectionEpoch = previousConnectionEpoch
        self.previousCodecEpoch = previousCodecEpoch
    }
}

public struct HostMediaControl: Sendable {
    public enum Command: String, Sendable {
        case startCapture
        case stopCapture
        case reconfigure
        case requestIdr
    }

    public let command: Command
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let codec: HostMediaCodec?
    public let width: UInt32?
    public let height: UInt32?
    public let framesPerSecond: UInt32?
    public let bitRate: UInt32?
    public let reason: String?
    public let displayReconfigure: HostDisplayReconfigureProvenance?
}

/// Low-frequency, sanitized evidence that a compressed access unit crossed
/// the existing RustDesk writer/ACK path. It deliberately contains no peer
/// identifier, encoded bytes, screen content, password, or server material.
public struct HostMediaDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case firstPacketDispatched
        case firstPacketAcknowledged
        case refreshKeyframeDispatched
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let codec: HostMediaCodec
    public let framing: HostMediaFraming
    public let presentationTimeUS: UInt64
    public let isKeyframe: Bool
    public let hasParameterSets: Bool
    public let subscriberCount: UInt32
}

/// Low-frequency, aggregate occupancy sampled at the production Rust encoded
/// queue. This event is carried by the existing Host event callback and does
/// not expose payload bytes, peer identity, transport credentials, or server
/// material.
public struct HostMediaQueueDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case sample
        case routeStopped
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let currentDepth: UInt32
    public let maximumDepth: UInt32
    public let capacity: UInt32
}

/// Route-scoped cumulative wall-clock measurements from the synchronous
/// RustDesk video-service loop. Dispatch wall covers subscriber channel fanout;
/// confirmation wait covers the existing frame-controller fetch wait. Neither
/// value is encryption CPU time, socket-send time, RTT, nor remote ACK latency.
public struct HostMediaWriterDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case sample
        case routeStopped
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let cycles: UInt64
    public let subscriberDispatches: UInt64
    public let dispatchWallTotalUS: UInt64
    public let maximumDispatchWallUS: UInt64
    public let confirmationWaitTotalUS: UInt64
    public let maximumConfirmationWaitUS: UInt64
    public let completedConfirmations: UInt64
    public let timedOutConfirmations: UInt64
}

/// Low-frequency route-scoped network estimates from RustDesk's existing QoS
/// TestDelay path. Missing samples remain nil; no peer identity, transport
/// classification, packet-loss estimate, or server material is exported.
public struct HostMediaNetworkDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case sample
        case routeStopped
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let subscriberCount: UInt32
    public let qosSubscriberCount: UInt32
    public let delaySampledSubscribers: UInt32
    public let rttSampledSubscribers: UInt32
    public let responseDelayedSubscribers: UInt32
    public let worstNetworkDelayMS: UInt32?
    public let worstRTTMS: UInt32?
}

/// Route-scoped transport classification retained by the Rust connection
/// lifecycle registry. Only aggregate counts are exported; unknown remains an
/// explicit category instead of being inferred as direct or relay.
public struct HostMediaTransportDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case sample
        case routeStopped
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let subscriberCount: UInt32
    public let directSubscribers: UInt32
    public let relaySubscribers: UInt32
    public let unknownSubscribers: UInt32
}

extension HostCoreEvent {
    public var displayReconfigureStarted: HostDisplayReconfigureStarted? {
        guard eventType == "mediaDisplayReconfigureStarted", let payload = decodedPayload(),
            let generation = Self.uint64(payload, "displayReconfigureGeneration"), generation > 0,
            let displayID = Self.uint64(payload, "displayId"),
            let previousDisplayRevision = Self.uint64(payload, "previousDisplayRevision"),
            previousDisplayRevision > 0,
            let previousConnectionEpoch = Self.uint64(payload, "previousConnectionEpoch"),
            previousConnectionEpoch > 0,
            let previousCodecEpoch = Self.uint64(payload, "previousCodecEpoch"),
            previousCodecEpoch > 0
        else { return nil }
        return HostDisplayReconfigureStarted(
            generation: generation, displayID: displayID,
            previousDisplayRevision: previousDisplayRevision,
            previousConnectionEpoch: previousConnectionEpoch, previousCodecEpoch: previousCodecEpoch
        )
    }

    public var mediaControl: HostMediaControl? {
        guard eventType == "mediaControl", let payload = decodedPayload(),
            let rawCommand = payload["command"] as? String,
            let command = HostMediaControl.Command(rawValue: rawCommand)
        else { return nil }
        let codec: HostMediaCodec?
        switch payload["codec"] as? String {
        case "h264": codec = .h264
        case "h265": codec = .h265
        default: codec = nil
        }
        func uint32(_ key: String) -> UInt32? {
            guard let value = Self.uint64(payload, key), value <= UInt32.max else { return nil }
            return UInt32(value)
        }
        guard let connectionEpoch = Self.uint64(payload, "connectionEpoch"), connectionEpoch > 0,
            let codecEpoch = Self.uint64(payload, "codecEpoch"), codecEpoch > 0,
            let displayID = Self.uint64(payload, "displayId")
        else { return nil }
        let displayRevision = Self.uint64(payload, "displayRevision") ?? 0
        let displayReconfigure: HostDisplayReconfigureProvenance?
        if let rawProvenance = payload["displayReconfigure"] {
            guard command == .startCapture || command == .reconfigure,
                let provenance = rawProvenance as? [String: Any],
                let generation = Self.uint64(provenance, "displayReconfigureGeneration"),
                generation > 0,
                let previousDisplayRevision = Self.uint64(provenance, "previousDisplayRevision"),
                previousDisplayRevision > 0, previousDisplayRevision < UInt64.max,
                displayRevision == previousDisplayRevision + 1,
                let previousConnectionEpoch = Self.uint64(provenance, "previousConnectionEpoch"),
                previousConnectionEpoch > 0, connectionEpoch > previousConnectionEpoch,
                let previousCodecEpoch = Self.uint64(provenance, "previousCodecEpoch"),
                previousCodecEpoch > 0, codecEpoch > previousCodecEpoch
            else { return nil }
            displayReconfigure = HostDisplayReconfigureProvenance(
                generation: generation, previousDisplayRevision: previousDisplayRevision,
                previousConnectionEpoch: previousConnectionEpoch,
                previousCodecEpoch: previousCodecEpoch)
        } else {
            displayReconfigure = nil
        }
        if command == .reconfigure {
            guard codec != nil, let width = uint32("width"), width > 0,
                let height = uint32("height"), height > 0, let fps = uint32("fps"), fps > 0,
                displayRevision > 0
            else { return nil }
        }
        return HostMediaControl(
            command: command, connectionEpoch: connectionEpoch, codecEpoch: codecEpoch,
            displayID: displayID, displayRevision: displayRevision, codec: codec,
            width: uint32("width"), height: uint32("height"), framesPerSecond: uint32("fps"),
            bitRate: uint32("bitrate"), reason: payload["reason"] as? String,
            displayReconfigure: displayReconfigure)
    }

    private func decodedPayload() -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: rawJSON),
            let envelope = object as? [String: Any]
        else { return nil }
        return envelope["payload"] as? [String: Any]
    }

    private static func uint64(_ object: [String: Any], _ key: String) -> UInt64? {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.int64Value >= 0, number.doubleValue.isFinite,
            number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { return nil }
        return number.uint64Value
    }

    public var mediaDiagnostic: HostMediaDiagnostic? {
        guard eventType == "mediaDiagnostic",
            let object = try? JSONSerialization.jsonObject(with: rawJSON),
            let envelope = object as? [String: Any],
            let payload = envelope["payload"] as? [String: Any],
            let rawKind = payload["kind"] as? String,
            let kind = HostMediaDiagnostic.Kind(rawValue: rawKind),
            let codecName = payload["codec"] as? String,
            let framingName = payload["framing"] as? String,
            let isKeyframe = payload["keyframe"] as? Bool,
            let hasParameterSets = payload["hasParameterSets"] as? Bool
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(), number.int64Value >= 0,
                number.doubleValue.isFinite,
                number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
            let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
            let displayID = uint64("displayId"), let displayRevision = uint64("displayRevision"),
            displayRevision > 0, let presentationTimeUS = uint64("ptsUs"),
            let rawSubscriberCount = uint64("subscriberCount"), rawSubscriberCount > 0,
            rawSubscriberCount <= UInt32.max
        else { return nil }
        let codec: HostMediaCodec
        switch codecName {
        case "h264": codec = .h264
        case "h265": codec = .h265
        default: return nil
        }
        let framing: HostMediaFraming
        switch framingName {
        case "annexB": framing = .annexB
        case "avcc": framing = .avcc
        default: return nil
        }
        return HostMediaDiagnostic(
            kind: kind, connectionEpoch: connectionEpoch, codecEpoch: codecEpoch,
            displayID: displayID, displayRevision: displayRevision, codec: codec, framing: framing,
            presentationTimeUS: presentationTimeUS, isKeyframe: isKeyframe,
            hasParameterSets: hasParameterSets, subscriberCount: UInt32(rawSubscriberCount))
    }

    public var mediaQueueDiagnostic: HostMediaQueueDiagnostic? {
        guard eventType == "mediaQueueDiagnostic",
            let object = try? JSONSerialization.jsonObject(with: rawJSON),
            let envelope = object as? [String: Any],
            let payload = envelope["payload"] as? [String: Any],
            let rawKind = payload["kind"] as? String,
            let kind = HostMediaQueueDiagnostic.Kind(rawValue: rawKind)
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(), number.int64Value >= 0,
                number.doubleValue.isFinite,
                number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
            let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
            let displayID = uint64("displayId"), let displayRevision = uint64("displayRevision"),
            displayRevision > 0, let currentDepth = uint64("currentDepth"),
            currentDepth <= UInt32.max, let maximumDepth = uint64("maximumDepth"),
            maximumDepth <= UInt32.max, let capacity = uint64("capacity"), capacity > 0,
            capacity <= UInt32.max, currentDepth <= maximumDepth, maximumDepth <= capacity
        else { return nil }
        return HostMediaQueueDiagnostic(
            kind: kind, connectionEpoch: connectionEpoch, codecEpoch: codecEpoch,
            displayID: displayID, displayRevision: displayRevision,
            currentDepth: UInt32(currentDepth), maximumDepth: UInt32(maximumDepth),
            capacity: UInt32(capacity))
    }

    public var mediaWriterDiagnostic: HostMediaWriterDiagnostic? {
        guard eventType == "mediaWriterDiagnostic",
            let object = try? JSONSerialization.jsonObject(with: rawJSON),
            let envelope = object as? [String: Any],
            let payload = envelope["payload"] as? [String: Any],
            let rawKind = payload["kind"] as? String,
            let kind = HostMediaWriterDiagnostic.Kind(rawValue: rawKind)
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(), number.int64Value >= 0,
                number.doubleValue.isFinite,
                number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
            let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
            let displayID = uint64("displayId"), let displayRevision = uint64("displayRevision"),
            displayRevision > 0, let cycles = uint64("cycles"),
            let subscriberDispatches = uint64("subscriberDispatches"),
            let dispatchWallTotalUS = uint64("dispatchWallTotalUs"),
            let maximumDispatchWallUS = uint64("maximumDispatchWallUs"),
            let confirmationWaitTotalUS = uint64("confirmationWaitTotalUs"),
            let maximumConfirmationWaitUS = uint64("maximumConfirmationWaitUs"),
            let completedConfirmations = uint64("completedConfirmations"),
            let timedOutConfirmations = uint64("timedOutConfirmations"),
            maximumDispatchWallUS <= dispatchWallTotalUS,
            maximumConfirmationWaitUS <= confirmationWaitTotalUS
        else { return nil }
        let (confirmationCycles, overflow) = completedConfirmations.addingReportingOverflow(
            timedOutConfirmations)
        guard !overflow, confirmationCycles == cycles else { return nil }
        if cycles == 0 {
            guard subscriberDispatches == 0, dispatchWallTotalUS == 0, maximumDispatchWallUS == 0,
                confirmationWaitTotalUS == 0, maximumConfirmationWaitUS == 0
            else { return nil }
        } else {
            guard subscriberDispatches >= cycles else { return nil }
        }
        return HostMediaWriterDiagnostic(
            kind: kind, connectionEpoch: connectionEpoch, codecEpoch: codecEpoch,
            displayID: displayID, displayRevision: displayRevision, cycles: cycles,
            subscriberDispatches: subscriberDispatches, dispatchWallTotalUS: dispatchWallTotalUS,
            maximumDispatchWallUS: maximumDispatchWallUS,
            confirmationWaitTotalUS: confirmationWaitTotalUS,
            maximumConfirmationWaitUS: maximumConfirmationWaitUS,
            completedConfirmations: completedConfirmations,
            timedOutConfirmations: timedOutConfirmations)
    }

    public var mediaNetworkDiagnostic: HostMediaNetworkDiagnostic? {
        guard eventType == "mediaNetworkDiagnostic",
            let object = try? JSONSerialization.jsonObject(with: rawJSON),
            let envelope = object as? [String: Any],
            let payload = envelope["payload"] as? [String: Any],
            let rawKind = payload["kind"] as? String,
            let kind = HostMediaNetworkDiagnostic.Kind(rawValue: rawKind)
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(), number.int64Value >= 0,
                number.doubleValue.isFinite,
                number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        func uint32(_ key: String) -> UInt32? {
            guard let value = uint64(key), value <= UInt32.max else { return nil }
            return UInt32(value)
        }
        func nullableUInt32(_ key: String) -> UInt32?? {
            guard payload.keys.contains(key) else { return nil }
            if payload[key] is NSNull { return .some(nil) }
            guard let value = uint32(key) else { return nil }
            return .some(value)
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
            let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
            let displayID = uint64("displayId"), let displayRevision = uint64("displayRevision"),
            displayRevision > 0, let subscriberCount = uint32("subscriberCount"),
            let qosSubscriberCount = uint32("qosSubscriberCount"),
            let delaySampledSubscribers = uint32("delaySampledSubscribers"),
            let rttSampledSubscribers = uint32("rttSampledSubscribers"),
            let responseDelayedSubscribers = uint32("responseDelayedSubscribers"),
            let parsedNetworkDelay = nullableUInt32("worstNetworkDelayMs"),
            let parsedRTT = nullableUInt32("worstRttMs"), qosSubscriberCount <= subscriberCount,
            delaySampledSubscribers <= qosSubscriberCount,
            rttSampledSubscribers <= delaySampledSubscribers,
            responseDelayedSubscribers <= qosSubscriberCount,
            (delaySampledSubscribers == 0) == (parsedNetworkDelay == nil),
            (rttSampledSubscribers == 0) == (parsedRTT == nil)
        else { return nil }
        return HostMediaNetworkDiagnostic(
            kind: kind, connectionEpoch: connectionEpoch, codecEpoch: codecEpoch,
            displayID: displayID, displayRevision: displayRevision,
            subscriberCount: subscriberCount, qosSubscriberCount: qosSubscriberCount,
            delaySampledSubscribers: delaySampledSubscribers,
            rttSampledSubscribers: rttSampledSubscribers,
            responseDelayedSubscribers: responseDelayedSubscribers,
            worstNetworkDelayMS: parsedNetworkDelay, worstRTTMS: parsedRTT)
    }

    public var mediaTransportDiagnostic: HostMediaTransportDiagnostic? {
        guard eventType == "mediaTransportDiagnostic",
            let object = try? JSONSerialization.jsonObject(with: rawJSON),
            let envelope = object as? [String: Any],
            let payload = envelope["payload"] as? [String: Any],
            let rawKind = payload["kind"] as? String,
            let kind = HostMediaTransportDiagnostic.Kind(rawValue: rawKind)
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(), number.int64Value >= 0,
                number.doubleValue.isFinite,
                number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        func uint32(_ key: String) -> UInt32? {
            guard let value = uint64(key), value <= UInt32.max else { return nil }
            return UInt32(value)
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
            let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
            let displayID = uint64("displayId"), let displayRevision = uint64("displayRevision"),
            displayRevision > 0, let subscriberCount = uint32("subscriberCount"),
            let directSubscribers = uint32("directSubscribers"),
            let relaySubscribers = uint32("relaySubscribers"),
            let unknownSubscribers = uint32("unknownSubscribers"),
            UInt64(directSubscribers) + UInt64(relaySubscribers) + UInt64(unknownSubscribers)
                == UInt64(subscriberCount)
        else { return nil }
        return HostMediaTransportDiagnostic(
            kind: kind, connectionEpoch: connectionEpoch, codecEpoch: codecEpoch,
            displayID: displayID, displayRevision: displayRevision,
            subscriberCount: subscriberCount, directSubscribers: directSubscribers,
            relaySubscribers: relaySubscribers, unknownSubscribers: unknownSubscribers)
    }

}

extension HostMediaControl {
    public func matchesRoute(_ other: HostMediaControl) -> Bool {
        connectionEpoch == other.connectionEpoch && codecEpoch == other.codecEpoch
            && displayID == other.displayID
            && (displayRevision == 0 || other.displayRevision == 0
                || displayRevision == other.displayRevision)
    }
}

extension HostMediaDiagnostic {
    public func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch && codecEpoch == route.codecEpoch
            && displayID == route.displayID && displayRevision == route.displayRevision
    }
}

extension HostMediaQueueDiagnostic {
    public func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch && codecEpoch == route.codecEpoch
            && displayID == route.displayID && displayRevision == route.displayRevision
    }
}

extension HostMediaWriterDiagnostic {
    public func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch && codecEpoch == route.codecEpoch
            && displayID == route.displayID && displayRevision == route.displayRevision
    }
}

extension HostMediaNetworkDiagnostic {
    public func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch && codecEpoch == route.codecEpoch
            && displayID == route.displayID && displayRevision == route.displayRevision
    }
}

extension HostMediaTransportDiagnostic {
    public func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch && codecEpoch == route.codecEpoch
            && displayID == route.displayID && displayRevision == route.displayRevision
    }
}
