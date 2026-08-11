@testable import CoreBridge
import Darwin
import Foundation
import XCTest

final class HostFileTransferReceiveRootProvisionerTests: XCTestCase {
    func testCreatesPrivateFixedChildAndIsIdempotent() throws {
        let fixture = try makeParent()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try XCTUnwrap(
            HostFileTransferReceiveRootProvisioner.provision(
                inside: fixture.parent
            )
        )
        let second = try XCTUnwrap(
            HostFileTransferReceiveRootProvisioner.provision(
                inside: fixture.parent
            )
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "FarPane Receive")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: first.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
            geteuid()
        )
    }

    func testRejectsUnsafeParentAndExistingChildWithoutChangingThem() throws {
        let loose = try makeParent(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: loose.root) }
        XCTAssertNil(
            HostFileTransferReceiveRootProvisioner.provision(
                inside: loose.parent
            )
        )

        let symlink = try makeParent()
        defer { try? FileManager.default.removeItem(at: symlink.root) }
        let outside = symlink.root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        let child = symlink.parent.appendingPathComponent("FarPane Receive")
        try FileManager.default.createSymbolicLink(
            at: child,
            withDestinationURL: outside
        )

        XCTAssertNil(
            HostFileTransferReceiveRootProvisioner.provision(
                inside: symlink.parent
            )
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: child.path
            ),
            outside.path
        )
    }

    private func makeParent(
        mode: Int = 0o700
    ) throws -> (root: URL, parent: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HostFileTransferReceiveRootProvisionerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let parent = root.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: parent.path
        )
        return (root, parent)
    }
}
