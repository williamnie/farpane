import Foundation
import Darwin

package enum ViewerFileTransferUploadReadAdapterResult: Equatable, Sendable {
    case success(bytesWritten: Int)
    case rejected
}

/// Owns the exact upload request -> descriptor owner route used by the
/// synchronous Rust callback. It never publishes paths or descriptors.
package final class ViewerFileTransferUploadReadAdapter: @unchecked Sendable {
    private struct RouteKey: Hashable {
        let sessionEpoch: UInt64
        let transferID: Int32
    }

    private struct Route {
        let request: ViewerFileTransferUploadRequest
        let owner: ViewerFileTransferUploadSourceOwner
    }

    private static let maximumRoutes = 8
    private let lock = NSLock()
    private var routes: [RouteKey: Route] = [:]

    package init() {}

    package func begin(
        _ request: ViewerFileTransferUploadRequest,
        sourceOwner: ViewerFileTransferUploadSourceOwner
    ) -> Bool {
        guard
            sourceOwner.lease == request.source,
            sourceOwner.manifest == request.manifest
        else { return false }
        let key = RouteKey(
            sessionEpoch: request.sessionEpoch,
            transferID: request.transferID
        )
        return lock.withLock {
            guard routes.count < Self.maximumRoutes, routes[key] == nil else {
                return false
            }
            routes[key] = Route(request: request, owner: sourceOwner)
            return true
        }
    }

    package func read(
        sessionEpoch: UInt64,
        transferID: Int32,
        sourceToken: UInt64,
        fileNumber: UInt32,
        offset: UInt64,
        buffer: UnsafeMutablePointer<UInt8>,
        length: Int
    ) -> ViewerFileTransferUploadReadAdapterResult {
        guard
            sessionEpoch > 0,
            transferID > 0,
            sourceToken > 0,
            length > 0,
            length <= CoreFileTransferReceiveBlock.maximumPayloadBytes
        else { return .rejected }
        let key = RouteKey(sessionEpoch: sessionEpoch, transferID: transferID)
        guard let route = lock.withLock({ routes[key] }) else {
            return .rejected
        }
        let request = route.request
        guard
            request.source.token == sourceToken,
            Int(fileNumber) < request.manifest.files.count
        else { return .rejected }
        let file = request.manifest.files[Int(fileNumber)]
        let end = offset.addingReportingOverflow(UInt64(length))
        guard !end.overflow, offset < file.size, end.partialValue <= file.size else {
            return .rejected
        }
        guard route.owner.readPinnedBytes(
            for: request.source,
            fileNumber: Int(fileNumber),
            offset: offset,
            into: buffer,
            length: length
        ) else { return .rejected }
        guard lock.withLock({ routes[key]?.request == request }) else {
            memset(buffer, 0, length)
            return .rejected
        }
        return .success(bytesWritten: length)
    }

    @discardableResult
    package func observe(_ event: CoreFileTransferEvent) -> Bool {
        guard event.kind == .completed || event.kind == .cancelled || event.kind == .failed else {
            return false
        }
        let key = RouteKey(
            sessionEpoch: event.sessionEpoch,
            transferID: event.transferID
        )
        let route = lock.withLock { routes.removeValue(forKey: key) }
        guard let route else { return false }
        _ = route.owner.teardown(sessionEpoch: event.sessionEpoch)
        return true
    }

    @discardableResult
    package func rollback(sessionEpoch: UInt64, transferID: Int32) -> Bool {
        let key = RouteKey(sessionEpoch: sessionEpoch, transferID: transferID)
        let route = lock.withLock { routes.removeValue(forKey: key) }
        guard let route else { return false }
        _ = route.owner.teardown(sessionEpoch: sessionEpoch)
        return true
    }

    package func teardownAll() {
        let owned = lock.withLock {
            let owned = Array(routes.values)
            routes.removeAll(keepingCapacity: false)
            return owned
        }
        for route in owned {
            _ = route.owner.teardown(sessionEpoch: route.request.sessionEpoch)
        }
    }
}
