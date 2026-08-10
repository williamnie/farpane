import Darwin
import Foundation
@testable import CoreBridge
import XCTest

final class ViewerFileTransferDestinationOwnerTests: XCTestCase {
    func testPinsPrivateOwnedDirectoryForMatchingLease() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 41,
            directoryURL: directory,
            leaseToken: 91
        ))
        let lease = try XCTUnwrap(owner.lease)

        XCTAssertEqual(lease.sessionEpoch, 41)
        XCTAssertEqual(lease.token, 91)
        let identity = owner.withPinnedDirectoryDescriptor(for: lease) { descriptor in
            var status = stat()
            XCTAssertEqual(Darwin.fstat(descriptor, &status), 0)
            XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
            return [UInt64(status.st_dev), UInt64(status.st_ino)]
        }
        XCTAssertNotNil(identity)
    }

    func testRejectsUnsafeDirectoriesAndInvalidAuthority() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(ViewerFileTransferDestinationOwner(
            sessionEpoch: 0,
            directoryURL: directory,
            leaseToken: 1
        ))
        XCTAssertNil(ViewerFileTransferDestinationOwner(
            sessionEpoch: 1,
            directoryURL: directory,
            leaseToken: 0
        ))

        XCTAssertEqual(Darwin.chmod(directory.path, 0o755), 0)
        XCTAssertNil(ViewerFileTransferDestinationOwner(
            sessionEpoch: 1,
            directoryURL: directory,
            leaseToken: 1
        ))
        XCTAssertEqual(Darwin.chmod(directory.path, 0o700), 0)

        let file = directory.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        XCTAssertNil(ViewerFileTransferDestinationOwner(
            sessionEpoch: 1,
            directoryURL: file,
            leaseToken: 1
        ))

        let link = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertNil(ViewerFileTransferDestinationOwner(
            sessionEpoch: 1,
            directoryURL: link,
            leaseToken: 1
        ))
    }

    func testBorrowFailsClosedForStaleLeasePermissionDriftAndTeardown() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 72,
            directoryURL: directory,
            leaseToken: 19
        ))
        let lease = try XCTUnwrap(owner.lease)
        let staleEpoch = try XCTUnwrap(ViewerFileTransferDestinationLease(
            token: lease.token,
            sessionEpoch: lease.sessionEpoch + 1
        ))
        let staleToken = try XCTUnwrap(ViewerFileTransferDestinationLease(
            token: lease.token + 1,
            sessionEpoch: lease.sessionEpoch
        ))
        XCTAssertNil(owner.withPinnedDirectoryDescriptor(for: staleEpoch) { _ in true })
        XCTAssertNil(owner.withPinnedDirectoryDescriptor(for: staleToken) { _ in true })

        XCTAssertEqual(Darwin.chmod(directory.path, 0o777), 0)
        XCTAssertNil(owner.withPinnedDirectoryDescriptor(for: lease) { _ in true })
        XCTAssertEqual(Darwin.chmod(directory.path, 0o700), 0)
        XCTAssertEqual(owner.withPinnedDirectoryDescriptor(for: lease) { _ in true }, true)

        XCTAssertFalse(owner.teardown(sessionEpoch: 71))
        XCTAssertNotNil(owner.lease)
        XCTAssertTrue(owner.teardown(sessionEpoch: 72))
        XCTAssertNil(owner.lease)
        XCTAssertNil(owner.withPinnedDirectoryDescriptor(for: lease) { _ in true })
        XCTAssertFalse(owner.teardown(sessionEpoch: 72))
    }

    func testPinnedDescriptorDoesNotFollowReplacementAtSelectedPath() throws {
        let parent = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let selected = parent.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        XCTAssertEqual(Darwin.chmod(selected.path, 0o700), 0)

        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 18,
            directoryURL: selected,
            leaseToken: 27
        ))
        let lease = try XCTUnwrap(owner.lease)
        let originalInode = try XCTUnwrap(owner.withPinnedDirectoryDescriptor(for: lease) {
            descriptor -> ino_t? in
            var status = stat()
            return Darwin.fstat(descriptor, &status) == 0 ? status.st_ino : nil
        })

        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: selected, to: moved)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: parent)

        let borrowedInode = try XCTUnwrap(owner.withPinnedDirectoryDescriptor(for: lease) {
            descriptor -> ino_t? in
            var status = stat()
            return Darwin.fstat(descriptor, &status) == 0 ? status.st_ino : nil
        })
        XCTAssertEqual(borrowedInode, originalInode)

        let file = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "nested/one.txt",
            size: 4,
            modifiedTime: 10
        ))
        let request = try makeRequest(lease: lease, transferID: 3, file: file)
        let reservation = try XCTUnwrap(owner.reserveNewFile(
            for: request,
            fileNumber: 0,
            reservationToken: 33
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: moved.appendingPathComponent("nested/one.txt.farpane-part").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("nested/one.txt.farpane-part").path
        ))
        XCTAssertTrue(owner.cancelReservation(reservation))
    }

    func testReservesAndCancelsOnlyExactPrivateStagingFile() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 9,
            directoryURL: directory,
            leaseToken: 21
        ))
        let lease = try XCTUnwrap(owner.lease)
        let file = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "reports/one.txt",
            size: 4,
            modifiedTime: 10
        ))
        let request = try makeRequest(lease: lease, transferID: 7, file: file)
        XCTAssertNil(owner.reserveNewFile(
            for: request,
            fileNumber: 1,
            reservationToken: 30
        ))
        let unrepresentable = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "reports/huge.txt",
            size: UInt64.max,
            modifiedTime: 10
        ))
        let unrepresentableRequest = try makeRequest(
            lease: lease,
            transferID: 6,
            file: unrepresentable
        )
        XCTAssertNil(owner.reserveNewFile(
            for: unrepresentableRequest,
            fileNumber: 0,
            reservationToken: 29
        ))
        let reservation = try XCTUnwrap(owner.reserveNewFile(
            for: request,
            fileNumber: 0,
            reservationToken: 31
        ))
        XCTAssertEqual(reservation, ViewerFileTransferReceiveReservation(
            sessionEpoch: 9,
            transferID: 7,
            fileNumber: 0,
            token: 31
        ))

        let staging = directory.appendingPathComponent("reports/one.txt.farpane-part")
        var status = stat()
        XCTAssertEqual(Darwin.lstat(staging.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o600))
        XCTAssertEqual(status.st_uid, geteuid())
        XCTAssertEqual(status.st_nlink, 1)
        XCTAssertEqual(status.st_size, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("reports/one.txt").path
        ))
        XCTAssertNil(owner.reserveNewFile(
            for: request,
            fileNumber: 0,
            reservationToken: 32
        ))
        XCTAssertTrue(owner.cancelReservation(reservation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(owner.cancelReservation(reservation))

        XCTAssertTrue(FileManager.default.createFile(
            atPath: directory.appendingPathComponent("reports/one.txt").path,
            contents: Data()
        ))
        let existingRequest = try makeRequest(lease: lease, transferID: 8, file: file)
        XCTAssertNil(owner.reserveNewFile(
            for: existingRequest,
            fileNumber: 0,
            reservationToken: 32
        ))
    }

    func testReservationCapTeardownAndReplacementCleanupFailClosed() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 19,
            directoryURL: directory,
            leaseToken: 41
        ))
        let lease = try XCTUnwrap(owner.lease)
        var reservations: [ViewerFileTransferReceiveReservation] = []
        for index in 0..<ViewerFileTransferDestinationOwner.maximumActiveReservations {
            let file = try XCTUnwrap(ViewerFileTransferFile(
                relativePath: "file-\(index).txt",
                size: 1,
                modifiedTime: 0
            ))
            let request = try makeRequest(
                lease: lease,
                transferID: Int32(index + 1),
                file: file
            )
            reservations.append(try XCTUnwrap(owner.reserveNewFile(
                for: request,
                fileNumber: 0,
                reservationToken: UInt64(index + 101)
            )))
        }
        let overflow = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "overflow.txt",
            size: 1,
            modifiedTime: 0
        ))
        let overflowRequest = try makeRequest(lease: lease, transferID: 99, file: overflow)
        XCTAssertNil(owner.reserveNewFile(
            for: overflowRequest,
            fileNumber: 0,
            reservationToken: 999
        ))

        XCTAssertEqual(owner.writePayload(
            Data("x".utf8),
            to: reservations[1]
        ), 1)

        let firstStaging = directory.appendingPathComponent("file-0.txt.farpane-part")
        XCTAssertEqual(Darwin.unlink(firstStaging.path), 0)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: firstStaging.path,
            contents: Data("replacement".utf8)
        ))
        XCTAssertEqual(Darwin.chmod(firstStaging.path, 0o600), 0)
        XCTAssertFalse(owner.cancelReservation(reservations[0]))
        XCTAssertEqual(try Data(contentsOf: firstStaging), Data("replacement".utf8))

        XCTAssertTrue(owner.teardown(sessionEpoch: 19))
        for index in 1..<reservations.count {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    "file-\(index).txt.farpane-part"
                ).path
            ))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstStaging.path))
        XCTAssertNil(owner.lease)
    }

    func testWritesBoundedPayloadAtExactOffsetWithoutCommitting() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 29,
            directoryURL: directory,
            leaseToken: 51
        ))
        let lease = try XCTUnwrap(owner.lease)
        let file = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "payload.txt",
            size: 5,
            modifiedTime: 10
        ))
        let request = try makeRequest(lease: lease, transferID: 17, file: file)
        let reservation = try XCTUnwrap(owner.reserveNewFile(
            for: request,
            fileNumber: 0,
            reservationToken: 61
        ))
        let stale = ViewerFileTransferReceiveReservation(
            sessionEpoch: reservation.sessionEpoch,
            transferID: reservation.transferID,
            fileNumber: reservation.fileNumber,
            token: reservation.token + 1
        )
        XCTAssertNil(owner.writePayload(Data("bad".utf8), to: stale))

        XCTAssertEqual(owner.writePayload(Data("he".utf8), to: reservation), 2)
        XCTAssertEqual(owner.writePayload(Data("llo".utf8), to: reservation), 5)
        let staging = directory.appendingPathComponent("payload.txt.farpane-part")
        XCTAssertEqual(try Data(contentsOf: staging), Data("hello".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("payload.txt").path
        ))

        XCTAssertNil(owner.writePayload(Data("!".utf8), to: reservation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(owner.cancelReservation(reservation))
    }

    func testInvalidPayloadAndReplacementDriftAbortFailClosed() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try XCTUnwrap(ViewerFileTransferDestinationOwner(
            sessionEpoch: 39,
            directoryURL: directory,
            leaseToken: 71
        ))
        let lease = try XCTUnwrap(owner.lease)
        let file = try XCTUnwrap(ViewerFileTransferFile(
            relativePath: "drift.txt",
            size: UInt64(ViewerFileTransferDestinationOwner.maximumWriteChunkBytes + 1),
            modifiedTime: 0
        ))

        let emptyRequest = try makeRequest(lease: lease, transferID: 21, file: file)
        let emptyReservation = try XCTUnwrap(owner.reserveNewFile(
            for: emptyRequest,
            fileNumber: 0,
            reservationToken: 81
        ))
        XCTAssertNil(owner.writePayload(Data(), to: emptyReservation))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("drift.txt.farpane-part").path
        ))

        let oversizeRequest = try makeRequest(lease: lease, transferID: 22, file: file)
        let oversizeReservation = try XCTUnwrap(owner.reserveNewFile(
            for: oversizeRequest,
            fileNumber: 0,
            reservationToken: 82
        ))
        XCTAssertNil(owner.writePayload(
            Data(repeating: 1, count: ViewerFileTransferDestinationOwner.maximumWriteChunkBytes + 1),
            to: oversizeReservation
        ))

        let replacementRequest = try makeRequest(lease: lease, transferID: 23, file: file)
        let replacementReservation = try XCTUnwrap(owner.reserveNewFile(
            for: replacementRequest,
            fileNumber: 0,
            reservationToken: 83
        ))
        XCTAssertEqual(owner.writePayload(Data("safe".utf8), to: replacementReservation), 4)
        let staging = directory.appendingPathComponent("drift.txt.farpane-part")
        XCTAssertEqual(Darwin.unlink(staging.path), 0)
        let replacement = Data("replacement".utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: staging.path,
            contents: replacement
        ))
        XCTAssertEqual(Darwin.chmod(staging.path, 0o600), 0)
        XCTAssertNil(owner.writePayload(Data("next".utf8), to: replacementReservation))
        XCTAssertEqual(try Data(contentsOf: staging), replacement)
        XCTAssertFalse(owner.cancelReservation(replacementReservation))
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(Darwin.chmod(directory.path, 0o700), 0)
        return directory
    }

    private func makeRequest(
        lease: ViewerFileTransferDestinationLease,
        transferID: Int32,
        file: ViewerFileTransferFile
    ) throws -> ViewerFileTransferDownloadRequest {
        let manifest = try XCTUnwrap(ViewerFileTransferManifest(
            files: [file],
            emptyDirectories: []
        ))
        return try XCTUnwrap(ViewerFileTransferDownloadRequest(
            sessionEpoch: lease.sessionEpoch,
            transferID: transferID,
            destination: lease,
            manifest: manifest
        ))
    }
}
