import Foundation

package enum ViewerFileTransferRecursiveManifestPart: Equatable, Sendable {
    case files([ViewerFileTransferFile])
    case emptyDirectories([String])
}

package enum ViewerFileTransferRecursiveManifestOutcome: Equatable, Sendable {
    case awaitingRemainingPart
    case completed(ViewerFileTransferManifest)
    case failed(ViewerFileTransferFailure)
}

/// Joins the two bounded recursive-list responses for one exact Viewer file
/// session. This authority is transport-independent and owns no local storage
/// resource; a future ABI adapter must supply both semantic parts.
package struct ViewerFileTransferRecursiveManifestAuthority: Sendable {
    private struct ActiveRequest: Sendable {
        let sessionEpoch: UInt64
        let requestID: Int32
        var files: [ViewerFileTransferFile]?
        var emptyDirectories: [String]?
    }

    private var activeRequest: ActiveRequest?

    package init() {}

    package var isActive: Bool { activeRequest != nil }

    @discardableResult
    package mutating func begin(sessionEpoch: UInt64, requestID: Int32) -> Bool {
        guard sessionEpoch > 0, requestID > 0, activeRequest == nil else {
            return false
        }
        activeRequest = ActiveRequest(
            sessionEpoch: sessionEpoch,
            requestID: requestID,
            files: nil,
            emptyDirectories: nil
        )
        return true
    }

    package mutating func observe(
        sessionEpoch: UInt64,
        requestID: Int32,
        part: ViewerFileTransferRecursiveManifestPart
    ) -> ViewerFileTransferRecursiveManifestOutcome? {
        guard var active = exactRequest(sessionEpoch: sessionEpoch, requestID: requestID) else {
            return nil
        }

        switch part {
        case let .files(files):
            guard active.files == nil else {
                return failProtocolViolation()
            }
            guard Self.accepts(files: files) else {
                return failProtocolViolation()
            }
            active.files = files
        case let .emptyDirectories(emptyDirectories):
            guard active.emptyDirectories == nil else {
                return failProtocolViolation()
            }
            guard Self.accepts(emptyDirectories: emptyDirectories) else {
                return failProtocolViolation()
            }
            active.emptyDirectories = emptyDirectories
        }

        guard let files = active.files,
              let emptyDirectories = active.emptyDirectories
        else {
            activeRequest = active
            return .awaitingRemainingPart
        }
        guard let manifest = ViewerFileTransferManifest(
            files: files,
            emptyDirectories: emptyDirectories
        ) else {
            return failProtocolViolation()
        }
        activeRequest = nil
        return .completed(manifest)
    }

    package mutating func fail(
        sessionEpoch: UInt64,
        requestID: Int32,
        failure: ViewerFileTransferFailure
    ) -> ViewerFileTransferRecursiveManifestOutcome? {
        guard exactRequest(sessionEpoch: sessionEpoch, requestID: requestID) != nil else {
            return nil
        }
        switch failure {
        case .rejected, .unavailable, .connectionClosed:
            activeRequest = nil
            return .failed(failure)
        case .protocolViolation, .localIO:
            return nil
        }
    }

    @discardableResult
    package mutating func teardown(sessionEpoch: UInt64) -> Int32? {
        guard sessionEpoch > 0, activeRequest?.sessionEpoch == sessionEpoch else {
            return nil
        }
        let requestID = activeRequest?.requestID
        activeRequest = nil
        return requestID
    }

    private func exactRequest(sessionEpoch: UInt64, requestID: Int32) -> ActiveRequest? {
        guard
            sessionEpoch > 0,
            requestID > 0,
            let activeRequest,
            activeRequest.sessionEpoch == sessionEpoch,
            activeRequest.requestID == requestID
        else { return nil }
        return activeRequest
    }

    private mutating func failProtocolViolation()
        -> ViewerFileTransferRecursiveManifestOutcome
    {
        activeRequest = nil
        return .failed(.protocolViolation)
    }

    private static func accepts(files: [ViewerFileTransferFile]) -> Bool {
        guard files.count <= ViewerFileTransferManifest.maximumEntries else {
            return false
        }
        return acceptsMetadata(files.map(\.relativePath))
    }

    private static func accepts(emptyDirectories: [String]) -> Bool {
        guard
            emptyDirectories.count <= ViewerFileTransferManifest.maximumEntries,
            emptyDirectories.allSatisfy(ViewerFileTransferManifest.accepts(relativePath:))
        else { return false }
        return acceptsMetadata(emptyDirectories)
    }

    private static func acceptsMetadata(_ paths: [String]) -> Bool {
        var total = 0
        for path in paths {
            let next = total.addingReportingOverflow(path.utf8.count)
            guard
                !next.overflow,
                next.partialValue <= ViewerFileTransferManifest.maximumMetadataUTF8Bytes
            else { return false }
            total = next.partialValue
        }
        return true
    }
}
