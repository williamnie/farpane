package struct ViewerFileTransferUploadSourceLease: Equatable, Sendable {
    package let token: UInt64
    package let sessionEpoch: UInt64

    package init?(token: UInt64, sessionEpoch: UInt64) {
        guard token > 0, sessionEpoch > 0 else { return nil }
        self.token = token
        self.sessionEpoch = sessionEpoch
    }
}

/// Path-free immutable input for a future Viewer upload data plane. Source
/// paths and descriptors remain owned by `ViewerFileTransferUploadSourceOwner`.
package struct ViewerFileTransferUploadRequest: Equatable, Sendable {
    package let sessionEpoch: UInt64
    package let transferID: Int32
    package let source: ViewerFileTransferUploadSourceLease
    package let manifest: ViewerFileTransferManifest

    init?(
        sessionEpoch: UInt64,
        transferID: Int32,
        source: ViewerFileTransferUploadSourceLease,
        manifest: ViewerFileTransferManifest
    ) {
        guard
            sessionEpoch > 0,
            transferID > 0,
            source.sessionEpoch == sessionEpoch
        else { return nil }
        self.sessionEpoch = sessionEpoch
        self.transferID = transferID
        self.source = source
        self.manifest = manifest
    }
}
