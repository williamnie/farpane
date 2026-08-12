import XCTest

final class NativeHostConnectionManagerIsolationTests: XCTestCase {
    func testNativeHostConnectionManagerAuthorityIsProcessLifetime() throws {
        let hostBridge = try source(
            "CoreBridge/RustDeskPatch/rdn_host_bridge.rs"
        )
        let authority = try XCTUnwrap(hostBridge.range(
            of: "pub(crate) fn native_host_owns_connection_manager() -> bool"
        ))
        let authorityTail = hostBridge[authority.lowerBound...]
        let authorityBodyEnd = try XCTUnwrap(authorityTail.range(of: "\n}"))
        let authorityBody = authorityTail[..<authorityBodyEnd.upperBound]

        XCTAssertTrue(authorityBody.contains(
            "CONFIG_ROOT_SET.load(Ordering::Acquire)"
        ))
        XCTAssertFalse(authorityBody.contains("HOST_INSTANCE_LIVE"))
        XCTAssertFalse(authorityBody.contains("MEDIA_BROKER"))
    }

    func testEveryNativeHostCMEntryUsesPersistentOwnershipGate() throws {
        let basePatch = try source(
            "CoreBridge/RustDeskPatch/upstream-1.4.9.patch"
        )
        let lifetimePatch = try source(
            "CoreBridge/RustDeskPatch/h7-native-host-cm-lifetime.patch"
        )
        let tryStartCM = try XCTUnwrap(basePatch.range(of: "+    fn try_start_cm("))
        let tryStartCMIPC = try XCTUnwrap(basePatch.range(
            of: "     fn try_start_cm_ipc(&mut self)"
        ))

        let cmPresentationPath = basePatch[
            tryStartCM.lowerBound..<tryStartCMIPC.lowerBound
        ]
        let cmIPCPath = basePatch[
            tryStartCMIPC.lowerBound..<basePatch.endIndex
        ]

        XCTAssertTrue(cmPresentationPath.contains(
            "+        if !connection_manager_required() {"
        ))
        XCTAssertTrue(cmIPCPath.contains(
            "+        if !connection_manager_required() {"
        ))
        XCTAssertTrue(lifetimePatch.contains(
            "crate::rdn_host_bridge::native_host_owns_connection_manager()"
        ))
        XCTAssertFalse(lifetimePatch.contains(
            "+            crate::rdn_host_bridge::native_host_is_bound()"
        ))
        XCTAssertFalse(lifetimePatch.contains(
            "+            crate::rdn_host_bridge::native_host_instance_is_live()"
        ))
    }

    func testLegacyCMRolesAreRejectedBeforeAppKit() throws {
        let app = try source("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let rejection = try XCTUnwrap(app.range(
            of: "case .unsupportedConnectionManager:"
        ))
        let appKit = try XCTUnwrap(app.range(of: "NSApplication.shared"))

        XCTAssertLessThan(rejection.lowerBound, appKit.lowerBound)
        XCTAssertTrue(app.contains(
            "RustDeskNativeConnectionManagerRejectionPolicy.exitCode"
        ))
    }

    private func source(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
