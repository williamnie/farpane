import CoreBridgeShim
import Foundation

public enum CoreDisplayCatalogStatus: UInt32, Equatable, Sendable {
    case available = 1
    case unavailable = 2
}

public struct CoreDisplayCatalogEntry: Equatable, Sendable {
    public let displayIndex: UInt32
    public let x: Int32
    public let y: Int32
    public let width: Int32
    public let height: Int32
    public let online: Bool
    public let scale: Double
    public let name: String

    public init?(
        displayIndex: UInt32, x: Int32, y: Int32, width: Int32, height: Int32, online: Bool,
        scale: Double, name: String
    ) {
        let validGeometry = online ? (width > 0 && height > 0) : (width >= 0 && height >= 0)
        guard validGeometry, scale.isFinite, scale > 0, scale <= 16,
            name.utf8.count <= Int(RDN_MAX_DISPLAY_NAME_UTF8_BYTES),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        self.displayIndex = displayIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.online = online
        self.scale = scale
        self.name = name
    }
}

public struct CoreDisplayCatalogEvent: Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let catalogRevision: UInt64
    public let status: CoreDisplayCatalogStatus
    public let selectedDisplayIndex: UInt32?
    public let entries: [CoreDisplayCatalogEntry]

    public init?(
        connectionEpoch: UInt64, catalogRevision: UInt64, status: CoreDisplayCatalogStatus,
        selectedDisplayIndex: UInt32?, entries: [CoreDisplayCatalogEntry]
    ) {
        guard connectionEpoch > 0, catalogRevision > 0,
            entries.count <= Int(RDN_MAX_DISPLAY_CATALOG_ENTRIES)
        else { return nil }
        switch status {
        case .available:
            guard
                entries.enumerated().allSatisfy({ offset, entry in
                    entry.displayIndex == UInt32(offset)
                })
            else { return nil }
            if let selectedDisplayIndex {
                guard entries.indices.contains(Int(selectedDisplayIndex)),
                    entries[Int(selectedDisplayIndex)].online
                else { return nil }
            }
        case .unavailable: guard entries.isEmpty, selectedDisplayIndex == nil else { return nil }
        }
        self.connectionEpoch = connectionEpoch
        self.catalogRevision = catalogRevision
        self.status = status
        self.selectedDisplayIndex = selectedDisplayIndex
        self.entries = entries
    }
}

public struct CoreDisplayCatalogProjectionState: Sendable {
    private var current: CoreDisplayCatalogEvent?
    private var deliveryEnabled = true

    public init() {}

    @discardableResult public mutating func observe(_ event: CoreDisplayCatalogEvent) -> Bool {
        guard deliveryEnabled else { return false }
        if let current {
            guard event.connectionEpoch >= current.connectionEpoch else { return false }
            if event.connectionEpoch == current.connectionEpoch {
                guard event.catalogRevision >= current.catalogRevision else { return false }
                if event.catalogRevision == current.catalogRevision {
                    guard event.status == current.status, event.entries == current.entries else {
                        return false
                    }
                }
            }
        }
        current = event
        return true
    }

    public func acceptsFrame(connectionEpoch: UInt64, catalogRevision: UInt64, displayIndex: UInt32)
        -> Bool
    {
        guard deliveryEnabled, let current, current.status == .available else { return false }
        return current.connectionEpoch == connectionEpoch
            && current.catalogRevision == catalogRevision
            && current.selectedDisplayIndex == displayIndex
    }

    func isCurrent(_ event: CoreDisplayCatalogEvent) -> Bool { deliveryEnabled && current == event }

    public mutating func stop() {
        deliveryEnabled = false
        current = nil
    }
}

public enum CoreDisplaySelectionResult: UInt32, Equatable, Sendable {
    case selected = 1
    case alreadySelected = 2
    case failed = 3
}

public enum CoreDisplaySelectionFailure: UInt32, Equatable, Sendable {
    case none = 0
    case catalogChanged = 1
    case connectionClosed = 2
    case remoteSelectionDrift = 3
}

public struct CoreDisplaySelectionRequest: Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let commandID: UInt64
    public let catalogRevision: UInt64
    public let displayIndex: UInt32

    public init?(
        connectionEpoch: UInt64, commandID: UInt64, catalogRevision: UInt64, displayIndex: UInt32
    ) {
        guard connectionEpoch > 0, commandID > 0, catalogRevision > 0 else { return nil }
        self.connectionEpoch = connectionEpoch
        self.commandID = commandID
        self.catalogRevision = catalogRevision
        self.displayIndex = displayIndex
    }
}

public struct CoreDisplaySelectionEvent: Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let commandID: UInt64
    public let catalogRevision: UInt64
    public let displayIndex: UInt32
    public let result: CoreDisplaySelectionResult
    public let failure: CoreDisplaySelectionFailure

    public init?(
        connectionEpoch: UInt64, commandID: UInt64, catalogRevision: UInt64, displayIndex: UInt32,
        result: CoreDisplaySelectionResult, failure: CoreDisplaySelectionFailure
    ) {
        guard connectionEpoch > 0, commandID > 0, catalogRevision > 0 else { return nil }
        switch result {
        case .selected, .alreadySelected: guard failure == .none else { return nil }
        case .failed: guard failure != .none else { return nil }
        }
        self.connectionEpoch = connectionEpoch
        self.commandID = commandID
        self.catalogRevision = catalogRevision
        self.displayIndex = displayIndex
        self.result = result
        self.failure = failure
    }
}

public struct CoreRuntimeMetrics: Sendable {
    public let remoteFPS: Double
    public let networkDelayMS: Int32
    public let targetBitrate: UInt64
}

public struct CoreClipboardRichTextPayload: Sendable, Equatable {
    public let plainText: String?
    public let rtf: String?
    public let html: String?

    public init(plainText: String? = nil, rtf: String? = nil, html: String? = nil) {
        self.plainText = plainText
        self.rtf = rtf
        self.html = html
    }
}

public enum CoreClipboardImagePayload: Sendable, Equatable {
    case rgba(width: UInt32, height: UInt32, pixels: Data)
    case png(Data)
    case svg(String)
}
