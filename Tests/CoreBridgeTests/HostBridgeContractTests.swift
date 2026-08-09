import CoreBridgeShim
import Darwin
import XCTest

// All host ABI functions are resolved through raw-pointer C signatures; the
// struct payload layouts below are asserted in testHostStructLayoutMatchesCABI.

struct HostCreateOptionsRaw {
    var abiVersion: UInt32
    var rendezvousServer: UnsafePointer<CChar>?
    var relayServer: UnsafePointer<CChar>?
    var serverPublicKey: UnsafePointer<CChar>?
}

struct HostCallbacksRaw {
    var abiVersion: UInt32
    var onEvent: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int) -> Void)?
    var context: UnsafeMutableRawPointer?
}

struct HostOwnedBytesRaw {
    var data: UnsafeMutablePointer<UInt8>?
    var length: Int
    var capacity: Int

    init() {
        data = nil
        length = 0
        capacity = 0
    }
}

struct HostEncoderCapabilitiesRaw {
    var abiVersion: UInt32
    var hostInstanceID: UnsafePointer<CChar>?
    var h264Hardware: UInt32
    var h265Hardware: UInt32
    var maxWidth: UInt32
    var maxHeight: UInt32
    var maxFPS: UInt32
}

struct HostEncodedAccessUnitRaw {
    var abiVersion: UInt32
    var hostInstanceID: UnsafePointer<CChar>?
    var connectionEpoch: UInt64
    var codecEpoch: UInt64
    var displayID: UInt64
    var displayRevision: UInt64
    var codec: UInt32
    var framing: UInt32
    var flags: UInt32
    var presentationTimeUS: UInt64
    var data: UnsafePointer<UInt8>?
    var length: Int
}

/// Event collector reachable from a non-capturing C callback.
enum HostEventRecorder {
    static var events: [String] = []

    static let callback: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int
    ) -> Void = { _, json, length in
        guard let json else { return }
        let buffer = UnsafeRawBufferPointer(start: json, count: length)
        if let text = String(bytes: buffer, encoding: .utf8) {
            events.append(text)
        }
    }
}


/// Host Control ABI contract tests (§8.1, §20.2): the host namespace must
/// coexist with the viewer ABI v5, export its full symbol surface, and fail
/// closed on validation before any config-root switch has happened.
final class HostBridgeContractTests: XCTestCase {
    private static let hostABIVersion: UInt32 = 7
    private static let hostMediaABIVersion: UInt32 = 1
    private static let expectedUpstreamCommit = "6c578292e8ebbbec708b76986ba8c4bc7c509747"

    private var handle: UnsafeMutableRawPointer?

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["RDN_CORE_LIBRARY"] else {
            throw XCTSkip("set RDN_CORE_LIBRARY for the built-core host ABI test")
        }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw XCTSkip("unable to load core library: \(String(cString: dlerror()))")
        }
        self.handle = handle
    }

    override func tearDown() {
        if let handle {
            dlclose(handle)
        }
        handle = nil
    }

    private struct SymbolMissing: Error {}

    private func rawSymbol(_ name: String) throws -> UnsafeMutableRawPointer {
        guard let handle else { throw XCTSkip("no library handle") }
        guard let raw = dlsym(handle, name) else {
            XCTFail("host ABI symbol missing: \(name)")
            throw SymbolMissing()
        }
        return raw
    }

    func testHostABISurfaceIsExportedAlongsideViewerABI() throws {
        guard let handle else { throw XCTSkip("no library handle") }
        let viewerABI = unsafeBitCast(
            try rawSymbol("rdn_core_abi_version"),
            to: (@convention(c) () -> UInt32).self)
        XCTAssertEqual(viewerABI(), 5, "viewer ABI must stay at v5 alongside the host ABI")

        let hostABI = unsafeBitCast(
            try rawSymbol("rdn_host_abi_version"),
            to: (@convention(c) () -> UInt32).self)
        XCTAssertEqual(hostABI(), Self.hostABIVersion)
        let mediaABI = unsafeBitCast(
            try rawSymbol("rdn_host_media_abi_version"),
            to: (@convention(c) () -> UInt32).self)
        XCTAssertEqual(mediaABI(), Self.hostMediaABIVersion)

        let commit = unsafeBitCast(
            try rawSymbol("rdn_host_upstream_commit"),
            to: (@convention(c) () -> UnsafePointer<CChar>).self)
        XCTAssertEqual(String(cString: commit()), Self.expectedUpstreamCommit)

        // Full lifecycle surface must resolve; absence is a contract break.
        let surface = [
            "rdn_host_set_config_root",
            "rdn_host_create",
            "rdn_host_start",
            "rdn_host_stop",
            "rdn_host_command",
            "rdn_host_set_permanent_password",
            "rdn_host_copy_snapshot",
            "rdn_host_free_bytes",
            "rdn_host_destroy",
            "rdn_host_media_set_capabilities",
            "rdn_host_media_submit_access_unit",
            "rdn_host_media_report_encoder_state",
        ]
        for name in surface {
            XCTAssertNotNil(dlsym(handle, name), "host ABI symbol missing: \(name)")
        }
    }

    /// The production loader path (rdn_shim) must expose the host surface
    /// alongside the viewer ABI. Non-mutating: does not touch the config
    /// root or create instances, so it is safe to run in any test order.
    func testShimLoaderResolvesHostSurface() throws {
        guard let path = ProcessInfo.processInfo.environment["RDN_CORE_LIBRARY"] else {
            throw XCTSkip("set RDN_CORE_LIBRARY for the built-core host ABI test")
        }
        var error = [CChar](repeating: 0, count: 1024)
        var library: OpaquePointer?
        path.withCString { shimLibrary in
            library = rdn_shim_open(shimLibrary, &error, error.count)
        }
        guard let shimLibrary = library else {
            XCTFail("shim failed to load the core library: \(String(cString: error))")
            return
        }
        defer { rdn_shim_close(shimLibrary) }
        XCTAssertEqual(rdn_shim_abi_version(shimLibrary), 5, "viewer ABI must stay at v5")
        XCTAssertNotEqual(rdn_shim_host_available(shimLibrary), 0)
        XCTAssertEqual(rdn_shim_host_abi_version(shimLibrary), Self.hostABIVersion)
        XCTAssertEqual(
            rdn_shim_host_media_abi_version(shimLibrary),
            Self.hostMediaABIVersion)
        let hostCommit = rdn_shim_host_upstream_commit(shimLibrary).map { String(cString: $0) }
        XCTAssertEqual(hostCommit, Self.expectedUpstreamCommit)
    }

    /// Full in-process HostCore lifecycle (§6.2 spike form, §8.2–8.5):
    /// invalid-namespace validation → config-root switch → create → start →
    /// snapshot ready → temporary password reveal/regenerate → stop →
    /// destroy. Uses a throwaway test namespace so the isolated config root
    /// never collides with the product.
    /// NOTE: sets process-global RustDesk state; must be the only test in
    /// this process that switches the config root, so the fail-closed
    /// namespace validation runs at the top, before the switch.
    func testFullHostCoreLifecycle() throws {
        let environment = ProcessInfo.processInfo.environment
        let liveServer = environment["RDN_HOST_LIVE_SERVER"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveKey = environment["RDN_HOST_LIVE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (liveServer == nil) == (liveKey == nil) else {
            XCTFail("RDN_HOST_LIVE_SERVER and RDN_HOST_LIVE_KEY must be supplied together")
            return
        }
        let liveRegistration = liveServer != nil
        let rendezvousServer = strdup(liveServer ?? "127.0.0.1:21116")!
        let relayServer = strdup("")!
        let syntheticPublicKey = Data(repeating: 0xA5, count: 32).base64EncodedString()
        let serverPublicKey = strdup(liveKey ?? syntheticPublicKey)!
        let persistenceFailureServer = strdup("127.0.0.1:21118")!
        defer {
            free(rendezvousServer)
            free(relayServer)
            free(serverPublicKey)
            free(persistenceFailureServer)
        }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Preferences/FarPaneHostTestsRoot.FarPaneHostTests"
            )
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let setConfigRoot = unsafeBitCast(
            try rawSymbol("rdn_host_set_config_root"),
            to: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self)

        // Path-traversal and separator characters must be rejected before any
        // config-root switch; these calls happen while the root is still
        // unset, so they cannot mutate process state.
        XCTAssertEqual(setConfigRoot("../evil", "org"), -5)
        XCTAssertEqual(setConfigRoot("FarPaneHost", "a/b"), -5)
        XCTAssertEqual(setConfigRoot(nil, "org"), -1)
        XCTAssertEqual(setConfigRoot("", "org"), -5)
        let hostCreate = unsafeBitCast(
            try rawSymbol("rdn_host_create"),
            to: (@convention(c) (
                UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutableRawPointer?
            ) -> Int32).self)
        let hostStart = unsafeBitCast(
            try rawSymbol("rdn_host_start"),
            to: (@convention(c) (OpaquePointer?) -> Int32).self)
        let hostStop = unsafeBitCast(
            try rawSymbol("rdn_host_stop"),
            to: (@convention(c) (OpaquePointer?, UInt32) -> Int32).self)
        let hostCommand = unsafeBitCast(
            try rawSymbol("rdn_host_command"),
            to: (@convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Int32).self)
        let setPermanentPassword = unsafeBitCast(
            try rawSymbol("rdn_host_set_permanent_password"),
            to: (@convention(c) (
                OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UInt8>?, Int
            ) -> Int32).self)

        var noHostSecret = Array("no-host-canary".utf8)
        XCTAssertEqual(noHostSecret.withUnsafeMutableBufferPointer { buffer in
            "pw-no-host".withCString { commandID in
                setPermanentPassword(nil, commandID, buffer.baseAddress, buffer.count)
            }
        }, -1)
        XCTAssertEqual(noHostSecret, [UInt8](repeating: 0, count: "no-host-canary".utf8.count))
        let copySnapshot = unsafeBitCast(
            try rawSymbol("rdn_host_copy_snapshot"),
            to: (@convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32).self)
        // rdn_host_free_bytes takes RdnHostOwnedBytes by value; AAPCS64 passes
        // structs >16 bytes by reference, so the callee receives a pointer
        // to the struct in x0.
        let freeBytes = unsafeBitCast(
            try rawSymbol("rdn_host_free_bytes"),
            to: (@convention(c) (UnsafeRawPointer?) -> Void).self)
        let hostDestroy = unsafeBitCast(
            try rawSymbol("rdn_host_destroy"),
            to: (@convention(c) (OpaquePointer?) -> Void).self)
        let mediaSetCapabilities = unsafeBitCast(
            try rawSymbol("rdn_host_media_set_capabilities"),
            to: (@convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Int32).self)
        let mediaSubmitAccessUnit = unsafeBitCast(
            try rawSymbol("rdn_host_media_submit_access_unit"),
            to: (@convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Int32).self)

        /// create wrapper: options/callbacks/out are C structs behind raw pointers.
        func create(_ out: inout OpaquePointer?) -> Int32 {
            withUnsafePointer(to: &options) { optionsPtr in
                withUnsafePointer(to: &callbacks) { callbacksPtr in
                    withUnsafeMutablePointer(to: &out) { outPtr in
                        hostCreate(
                            UnsafeRawPointer(optionsPtr),
                            UnsafeRawPointer(callbacksPtr),
                            UnsafeMutableRawPointer(outPtr))
                    }
                }
            }
        }
        func copy(_ host: OpaquePointer?, _ into: inout HostOwnedBytesRaw) -> Int32 {
            withUnsafeMutablePointer(to: &into) { ptr in
                copySnapshot(host, UnsafeMutableRawPointer(ptr))
            }
        }
        func copyDictionary(_ host: OpaquePointer?) throws -> [String: Any] {
            var bytes = HostOwnedBytesRaw()
            XCTAssertEqual(copy(host, &bytes), 0)
            return try snapshotJSON(bytes, freeBytes: freeBytes)
        }
        func waitUntilRegistered(_ host: OpaquePointer?) throws -> [String: Any] {
            let deadline = Date().addingTimeInterval(30)
            var snapshot = try copyDictionary(host)
            while snapshot["registrationStatus"] as? String != "ready", Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                snapshot = try copyDictionary(host)
            }
            return snapshot
        }

        // create must fail closed before the config-root switch.
        var options = HostCreateOptionsRaw(
            abiVersion: Self.hostABIVersion,
            rendezvousServer: UnsafePointer(rendezvousServer),
            relayServer: UnsafePointer(relayServer),
            serverPublicKey: UnsafePointer(serverPublicKey))
        var callbacks = HostCallbacksRaw(
            abiVersion: Self.hostABIVersion,
            onEvent: nil,
            context: nil)
        var earlyHost: OpaquePointer?
        XCTAssertEqual(create(&earlyHost), -3)

        // Switch the config root once, with a test-only namespace.
        XCTAssertEqual(setConfigRoot("FarPaneHostTests", "FarPaneHostTestsRoot"), 0)
        XCTAssertEqual(setConfigRoot("FarPaneHostTests", "FarPaneHostTestsRoot"), -3)

        // Canonical server configuration is required and validated before
        // the singleton instance slot is acquired.
        let validPublicKey = options.serverPublicKey
        options.serverPublicKey = nil
        XCTAssertEqual(create(&earlyHost), -1)
        options.serverPublicKey = validPublicKey

        HostEventRecorder.events.removeAll()
        callbacks = HostCallbacksRaw(
            abiVersion: Self.hostABIVersion,
            onEvent: HostEventRecorder.callback,
            context: nil)
        var host: OpaquePointer?
        XCTAssertEqual(create(&host), 0)
        XCTAssertNotNil(host)

        // A second concurrent instance must be rejected (process-global
        // RustDesk state, §18 rule 1).
        var secondHost: OpaquePointer?
        XCTAssertEqual(create(&secondHost), -3)

        // Existing malformed Host TOML must fail before Config/Config2 lazy
        // loading can replace it with defaults. The failed instance is
        // disposable; after preserving/removing the exact bytes, a fresh
        // instance may perform the normal first-start creation path.
        let configDirectory = root
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let identityFile = configDirectory.appendingPathComponent("FarPaneHostTests.toml")
        let optionsFile = configDirectory.appendingPathComponent("FarPaneHostTests2.toml")
        let malformedIdentity = Data("not-toml = [".utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: identityFile.path,
            contents: malformedIdentity,
            attributes: [.posixPermissions: 0o600]
        ))
        XCTAssertEqual(hostStart(host), -20)
        XCTAssertEqual(try Data(contentsOf: identityFile), malformedIdentity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: optionsFile.path))
        hostDestroy(host)
        host = nil
        try FileManager.default.removeItem(at: identityFile)
        XCTAssertEqual(create(&host), 0)

        XCTAssertEqual(hostStart(host), 0)

        let snapshotDict = liveRegistration
            ? try waitUntilRegistered(host)
            : try copyDictionary(host)
        XCTAssertEqual(snapshotDict["schemaVersion"] as? Int, 5)
        XCTAssertTrue(snapshotDict["pendingApproval"] is NSNull)
        XCTAssertTrue(snapshotDict["activeSession"] is NSNull)
        XCTAssertEqual(
            snapshotDict["hostState"] as? String,
            liveRegistration ? "ready" : "starting")
        XCTAssertEqual(
            snapshotDict["registrationStatus"] as? String,
            liveRegistration ? "ready" : "pending")
        let localId = snapshotDict["localId"] as? String ?? ""
        XCTAssertFalse(localId.isEmpty)
        let hostInstanceID = snapshotDict["hostInstanceId"] as? String ?? ""
        XCTAssertFalse(hostInstanceID.isEmpty)
        let noActiveSession = """
            {"commandId":"session-none","name":"disconnectSession","connectionId":"\(hostInstanceID):1"}
            """
        XCTAssertEqual(noActiveSession.utf8CString.withUnsafeBytes {
            hostCommand(host, $0.bindMemory(to: UInt8.self).baseAddress, $0.count - 1)
        }, -24)
        let malformedSessionCommand = """
            {"commandId":"session-invalid","name":"disableInputForActiveSession","connectionId":"\(hostInstanceID):1","ignored":true}
            """
        XCTAssertEqual(malformedSessionCommand.utf8CString.withUnsafeBytes {
            hostCommand(host, $0.bindMemory(to: UInt8.self).baseAddress, $0.count - 1)
        }, -5)
        if let redacted = snapshotDict["temporaryPasswordPresentation"] as? [String: Any] {
            XCTAssertEqual(redacted["policy"] as? String, "redacted")
        } else {
            XCTFail("snapshot must carry temporaryPasswordPresentation")
        }
        if let passwordPolicy = snapshotDict["passwordPolicy"] as? [String: Any],
           let strengthPolicy = passwordPolicy["strengthPolicy"] as? [String: Any]
        {
            XCTAssertEqual(passwordPolicy["localPasswordSet"] as? Bool, false)
            XCTAssertEqual(passwordPolicy["effectivePasswordSet"] as? Bool, false)
            XCTAssertEqual(passwordPolicy["usingPresetPassword"] as? Bool, false)
            XCTAssertEqual(passwordPolicy["changeAllowed"] as? Bool, true)
            XCTAssertEqual(strengthPolicy["version"] as? Int, 1)
            XCTAssertEqual(strengthPolicy["minimumCharacters"] as? Int, 6)
            XCTAssertEqual(strengthPolicy["maximumCharacters"] as? Int, 128)
            XCTAssertEqual(strengthPolicy["maximumUtf8Bytes"] as? Int, 512)
        } else {
            XCTFail("snapshot must carry the permanent-password policy")
        }

        func assertSetPassword(
            _ bytes: [UInt8], expectedCode: Int32, commandID: String
        ) {
            var mutableBytes = bytes
            let result = commandID.withCString { commandID in
                mutableBytes.withUnsafeMutableBufferPointer { buffer in
                    setPermanentPassword(host, commandID, buffer.baseAddress, buffer.count)
                }
            }
            XCTAssertEqual(result, expectedCode)
            XCTAssertEqual(mutableBytes, [UInt8](repeating: 0, count: bytes.count))
        }

        // Every accepted pointer is wiped, including stable policy rejects.
        assertSetPassword([], expectedCode: -14, commandID: "pw-empty")
        assertSetPassword([0xFF, 0xFE], expectedCode: -13, commandID: "pw-utf8")
        assertSetPassword(Array("short".utf8), expectedCode: -15, commandID: "pw-short")
        assertSetPassword(Array(" leading-space".utf8), expectedCode: -18, commandID: "pw-space")
        assertSetPassword(Array("valid\npassword".utf8), expectedCode: -17, commandID: "pw-control")
        assertSetPassword(
            [UInt8](repeating: 0x61, count: 513),
            expectedCode: -16,
            commandID: "pw-long")
        var invalidCommandSecret = Array("invalid-command-canary".utf8)
        XCTAssertEqual(invalidCommandSecret.withUnsafeMutableBufferPointer { buffer in
            setPermanentPassword(host, nil, buffer.baseAddress, buffer.count)
        }, -1)
        XCTAssertEqual(
            invalidCommandSecret,
            [UInt8](repeating: 0, count: "invalid-command-canary".utf8.count))

        let canaryPassword = "H3-canary-9f4a"
        assertSetPassword(Array(canaryPassword.utf8), expectedCode: 0, commandID: "pw-set")
        let passwordSetSnapshot = try copyDictionary(host)
        let passwordSetPolicy = try XCTUnwrap(
            passwordSetSnapshot["passwordPolicy"] as? [String: Any])
        XCTAssertEqual(passwordSetPolicy["localPasswordSet"] as? Bool, true)
        XCTAssertEqual(passwordSetPolicy["effectivePasswordSet"] as? Bool, true)
        let serializedSnapshot = String(
            data: try JSONSerialization.data(withJSONObject: passwordSetSnapshot),
            encoding: .utf8) ?? ""
        XCTAssertFalse(serializedSnapshot.contains(canaryPassword))
        XCTAssertFalse(HostEventRecorder.events.joined().contains(canaryPassword))

        let clearPermanentPassword = #"{"commandId":"pw-clear","name":"clearPermanentPassword"}"#
        XCTAssertEqual(clearPermanentPassword.utf8CString.withUnsafeBytes {
            hostCommand(host, $0.bindMemory(to: UInt8.self).baseAddress, $0.count - 1)
        }, 0)
        let passwordClearedSnapshot = try copyDictionary(host)
        let passwordClearedPolicy = try XCTUnwrap(
            passwordClearedSnapshot["passwordPolicy"] as? [String: Any])
        XCTAssertEqual(passwordClearedPolicy["localPasswordSet"] as? Bool, false)
        XCTAssertEqual(passwordClearedPolicy["effectivePasswordSet"] as? Bool, false)

        // H1b media surface: capabilities are instance-scoped and ABI
        // versioned. Encoded bytes are rejected without an authoritative
        // subscriber route; they must never bypass Rust service negotiation.
        hostInstanceID.withCString { instanceID in
            var capabilities = HostEncoderCapabilitiesRaw(
                abiVersion: Self.hostMediaABIVersion,
                hostInstanceID: instanceID,
                h264Hardware: 1,
                h265Hardware: 0,
                maxWidth: 4096,
                maxHeight: 4096,
                maxFPS: 60
            )
            capabilities.abiVersion += 1
            XCTAssertEqual(withUnsafePointer(to: &capabilities) {
                mediaSetCapabilities(host, UnsafeRawPointer($0))
            }, -2)
            capabilities.abiVersion = Self.hostMediaABIVersion
            XCTAssertEqual(withUnsafePointer(to: &capabilities) {
                mediaSetCapabilities(host, UnsafeRawPointer($0))
            }, 0)

            let packet: [UInt8] = [0, 0, 0, 1, 0x67]
            packet.withUnsafeBufferPointer { packetBuffer in
                var accessUnit = HostEncodedAccessUnitRaw(
                    abiVersion: Self.hostMediaABIVersion,
                    hostInstanceID: instanceID,
                    connectionEpoch: 1,
                    codecEpoch: 1,
                    displayID: 0,
                    displayRevision: 1,
                    codec: 1,
                    framing: 1,
                    flags: 3,
                    presentationTimeUS: 1,
                    data: packetBuffer.baseAddress,
                    length: packetBuffer.count
                )
                XCTAssertEqual(withUnsafePointer(to: &accessUnit) {
                    mediaSubmitAccessUnit(host, UnsafeRawPointer($0))
                }, -3)
            }
        }

        // Regenerate + one-shot reveal (§9.2).
        let regenerate = #"{"commandId":"c1","name":"regenerateTemporaryPassword"}"#
        XCTAssertEqual(regenerate.utf8CString.withUnsafeBytes {
            hostCommand(host, $0.bindMemory(to: UInt8.self).baseAddress, $0.count - 1)
        }, 0)
        let reveal = #"{"commandId":"c2","name":"revealTemporaryPassword"}"#
        XCTAssertEqual(reveal.utf8CString.withUnsafeBytes {
            hostCommand(host, $0.bindMemory(to: UInt8.self).baseAddress, $0.count - 1)
        }, 0)
        var revealed = HostOwnedBytesRaw()
        XCTAssertEqual(copy(host, &revealed), 0)
        let revealedDict = try snapshotJSON(revealed, freeBytes: freeBytes)
        if let presentation = revealedDict["temporaryPasswordPresentation"] as? [String: Any] {
            XCTAssertEqual(presentation["policy"] as? String, "revealed")
            let revealedValue = presentation["value"] as? String ?? ""
            XCTAssertFalse(revealedValue.isEmpty)
        } else {
            XCTFail("revealed snapshot must carry temporaryPasswordPresentation")
        }

        // The reveal is one-shot: the next copy is redacted again.
        var followUp = HostOwnedBytesRaw()
        XCTAssertEqual(copy(host, &followUp), 0)
        let followUpDict = try snapshotJSON(followUp, freeBytes: freeBytes)
        if let followUpPresentation =
            followUpDict["temporaryPasswordPresentation"] as? [String: Any]
        {
            XCTAssertEqual(followUpPresentation["policy"] as? String, "redacted")
        } else {
            XCTFail("follow-up snapshot must carry temporaryPasswordPresentation")
        }

        XCTAssertEqual(hostStop(host, 0), 0)
        hostDestroy(host)

        // After destroy the instance slot is free again, and the isolated
        // identity remains stable across a full HostCore restart (§9.1).
        var revivedHost: OpaquePointer?
        XCTAssertEqual(create(&revivedHost), 0)
        XCTAssertEqual(hostStart(revivedHost), 0)
        let revivedSnapshot = liveRegistration
            ? try waitUntilRegistered(revivedHost)
            : try copyDictionary(revivedHost)
        XCTAssertEqual(revivedSnapshot["localId"] as? String, localId)
        if liveRegistration {
            XCTAssertEqual(revivedSnapshot["registrationStatus"] as? String, "ready")
        }

        // Upstream acknowledges Config::store even when confy cannot replace
        // the private identity file. The dedicated password setter must
        // compare the persisted verifier/salt, wipe the caller buffer, and
        // stop an already-running Host before returning the storage error.
        let identityBeforePasswordFailedWrite = try Data(contentsOf: identityFile)
        let optionsBeforePasswordFailedWrite = try Data(contentsOf: optionsFile)
        let entriesBeforePasswordFailedWrite = try Set(
            FileManager.default.contentsOfDirectory(atPath: configDirectory.path)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: configDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: configDirectory.path
            )
        }
        let persistenceCanary = "H4-persistence-canary-71"
        var persistenceSecret = Array(persistenceCanary.utf8)
        XCTAssertEqual(persistenceSecret.withUnsafeMutableBufferPointer { buffer in
            "pw-persistence-failure".withCString { commandID in
                setPermanentPassword(
                    revivedHost,
                    commandID,
                    buffer.baseAddress,
                    buffer.count
                )
            }
        }, -20)
        XCTAssertEqual(
            persistenceSecret,
            [UInt8](repeating: 0, count: persistenceCanary.utf8.count)
        )
        let passwordPersistenceFailureSnapshot = try copyDictionary(revivedHost)
        XCTAssertEqual(passwordPersistenceFailureSnapshot["hostState"] as? String, "error")
        XCTAssertEqual(
            passwordPersistenceFailureSnapshot["registrationStatus"] as? String,
            "degraded"
        )
        XCTAssertEqual(
            passwordPersistenceFailureSnapshot["lastError"] as? String,
            "configuration.passwordPersistenceFailed"
        )
        XCTAssertEqual(
            try Data(contentsOf: identityFile),
            identityBeforePasswordFailedWrite
        )
        XCTAssertEqual(
            try Data(contentsOf: optionsFile),
            optionsBeforePasswordFailedWrite
        )
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: configDirectory.path)),
            entriesBeforePasswordFailedWrite
        )
        XCTAssertFalse(HostEventRecorder.events.joined().contains(persistenceCanary))
        hostDestroy(revivedHost)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configDirectory.path
        )

        // A synchronous upstream setter can update Config2 in memory even
        // when confy cannot create its replacement file. The Host start must
        // re-read the fixed files, reject the stale persisted projection and
        // preserve both documents before creating its runtime.
        let identityBeforeFailedWrite = try Data(contentsOf: identityFile)
        let optionsBeforeFailedWrite = try Data(contentsOf: optionsFile)
        let entriesBeforeFailedWrite = try Set(FileManager.default.contentsOfDirectory(
            atPath: configDirectory.path
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: configDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: configDirectory.path
            )
        }
        options.rendezvousServer = UnsafePointer(persistenceFailureServer)
        var persistenceFailedHost: OpaquePointer?
        XCTAssertEqual(create(&persistenceFailedHost), 0)
        XCTAssertEqual(hostStart(persistenceFailedHost), -20)
        let persistenceFailureSnapshot = try copyDictionary(persistenceFailedHost)
        XCTAssertEqual(persistenceFailureSnapshot["hostState"] as? String, "error")
        XCTAssertEqual(
            persistenceFailureSnapshot["registrationStatus"] as? String,
            "degraded"
        )
        XCTAssertEqual(
            persistenceFailureSnapshot["lastError"] as? String,
            "configuration.storagePersistenceFailed"
        )
        XCTAssertEqual(try Data(contentsOf: identityFile), identityBeforeFailedWrite)
        XCTAssertEqual(try Data(contentsOf: optionsFile), optionsBeforeFailedWrite)
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: configDirectory.path)),
            entriesBeforeFailedWrite
        )
        hostDestroy(persistenceFailedHost)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configDirectory.path
        )

        XCTAssertFalse(HostEventRecorder.events.isEmpty)
        for encodedEvent in HostEventRecorder.events {
            let data = try XCTUnwrap(encodedEvent.data(using: .utf8))
            let object = try JSONSerialization.jsonObject(with: data)
            let envelope = try XCTUnwrap(object as? [String: Any])
            XCTAssertEqual(envelope["schemaVersion"] as? Int, 1)
        }

    }

    private func snapshotJSON(
        _ bytes: HostOwnedBytesRaw,
        freeBytes: (UnsafeRawPointer?) -> Void
    ) throws -> [String: Any] {
        var owned = bytes
        defer {
            withUnsafePointer(to: &owned) { ptr in
                freeBytes(UnsafeRawPointer(ptr))
            }
        }
        guard let data = bytes.data else { return [:] }
        let payload = Data(bytes: data, count: bytes.length)
        let object = try JSONSerialization.jsonObject(with: payload)
        return object as? [String: Any] ?? [:]
    }
}
