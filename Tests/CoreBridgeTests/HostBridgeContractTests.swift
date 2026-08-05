import CoreBridgeShim
import Darwin
import XCTest

// All host ABI functions are resolved through raw-pointer C signatures; the
// struct payload layouts below are asserted in testHostStructLayoutMatchesCABI.

struct HostCreateOptionsRaw {
    var abiVersion: UInt32
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
    private static let hostABIVersion: UInt32 = 1
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
            "rdn_host_copy_snapshot",
            "rdn_host_free_bytes",
            "rdn_host_destroy",
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
        func copy(_ into: inout HostOwnedBytesRaw) -> Int32 {
            withUnsafeMutablePointer(to: &into) { ptr in
                copySnapshot(host, UnsafeMutableRawPointer(ptr))
            }
        }

        // create must fail closed before the config-root switch.
        var options = HostCreateOptionsRaw(abiVersion: Self.hostABIVersion)
        var callbacks = HostCallbacksRaw(
            abiVersion: Self.hostABIVersion,
            onEvent: nil,
            context: nil)
        var earlyHost: OpaquePointer?
        XCTAssertEqual(create(&earlyHost), -3)

        // Switch the config root once, with a test-only namespace.
        XCTAssertEqual(setConfigRoot("FarPaneHostTests", "FarPaneHostTestsRoot"), 0)
        XCTAssertEqual(setConfigRoot("FarPaneHostTests", "FarPaneHostTestsRoot"), -3)

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

        XCTAssertEqual(hostStart(host), 0)

        var snapshot = HostOwnedBytesRaw()
        XCTAssertEqual(copy(&snapshot), 0)
        let snapshotDict = try snapshotJSON(snapshot, freeBytes: freeBytes)
        XCTAssertEqual(snapshotDict["hostState"] as? String, "ready")
        XCTAssertEqual(snapshotDict["registrationStatus"] as? String, "pending")
        let localId = snapshotDict["localId"] as? String ?? ""
        XCTAssertFalse(localId.isEmpty)
        if let redacted = snapshotDict["temporaryPasswordPresentation"] as? [String: Any] {
            XCTAssertEqual(redacted["policy"] as? String, "redacted")
        } else {
            XCTFail("snapshot must carry temporaryPasswordPresentation")
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
        XCTAssertEqual(copy(&revealed), 0)
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
        XCTAssertEqual(copy(&followUp), 0)
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

        // After destroy the instance slot is free again.
        var revivedHost: OpaquePointer?
        XCTAssertEqual(create(&revivedHost), 0)
        hostDestroy(revivedHost)

        XCTAssertFalse(HostEventRecorder.events.isEmpty)

        // Best-effort cleanup of the throwaway config root.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FarPaneHostTestsRoot")
        try? FileManager.default.removeItem(at: root)
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
