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
    }

    private func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(Darwin.chmod(directory.path, 0o700), 0)
        return directory
    }
}
