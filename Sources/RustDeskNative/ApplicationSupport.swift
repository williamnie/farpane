import AppKit
import ApplicationServices
import ConnectionCatalog
import CoreBridge
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import MetalKit
import VideoPipeline
import ViewerInput

final class CoreRecoveryCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private weak var client: RustDeskCoreClient?

    func attach(_ client: RustDeskCoreClient) {
        lock.lock()
        defer { lock.unlock() }
        self.client = client
    }

    func requestKeyframe(display: UInt32) -> Bool {
        lock.lock()
        let client = self.client
        lock.unlock()
        return client?.requestKeyframe(display: display) == true
    }
}

/// Back-deploys `MainActor.assumeIsolated` to the macOS 13 toolchain while
/// retaining its fail-fast main-queue precondition.
enum MainActorBackport {
    @inline(__always) static func assumeIsolated<T>(_ operation: @MainActor () throws -> T) rethrows
        -> T
    {
        dispatchPrecondition(condition: .onQueue(.main))
        return try withoutActuallyEscaping(operation) { operation in
            try unsafeBitCast(operation, to: (() throws -> T).self)()
        }
    }
}

// The filename intentionally differs from main.swift so Xcode and SwiftPM both
// treat the @main application delegate as the single executable entry point.

struct Options {
    var fixture: String?
    var coreLibrary: String?
    var serverEnvironment = "RDN_SERVER"
    var keyEnvironment = "RDN_SERVER_PUBLIC_KEY"
    var peerIDEnvironment = "RDN_PEER_ID"
    var passwordEnvironment = "RDN_PASSWORD"
    var forceRelay = false
    var width = 0
    var height = 0
    var fps = 30.0
    var duration = 600.0
    var output = "Benchmarks/latest.json"
    var gpu = GPUPreference.automatic
    var fullscreen = false

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : ""
            switch key {
            case "--fixture": fixture = value
            case "--core": coreLibrary = value
            case "--server-env": serverEnvironment = value
            case "--key-env": keyEnvironment = value
            case "--peer-id-env": peerIDEnvironment = value
            case "--password-env": passwordEnvironment = value
            case "--force-relay": forceRelay = value != "false"
            case "--width": width = Int(value) ?? 0
            case "--height": height = Int(value) ?? 0
            case "--fps": fps = Double(value) ?? 30
            case "--duration": duration = Double(value) ?? 600
            case "--output": output = value
            case "--gpu": gpu = GPUPreference(rawValue: value) ?? .automatic
            case "--fullscreen": fullscreen = value != "false"
            case "--help":
                print(
                    "Fixture: RustDeskNative --fixture FILE --width PX --height PX [--fps 30] [--duration 600] [--gpu automatic|low-power|high-performance] [--fullscreen true|false] [--output FILE]"
                )
                print(
                    "Live: set RDN_SERVER/RDN_SERVER_PUBLIC_KEY/RDN_PEER_ID and run RustDeskNative --core DYLIB [--password-env RDN_PASSWORD] [--force-relay true|false] [--duration 1800] [--output FILE]"
                )
                exit(0)
            default: index -= 1
            }
            index += 2
        }
    }
}

struct PendingProductConnection {
    let attemptID: UUID
    let deviceID: UUID
    let deviceExisted: Bool
    let peerID: String
    var password: String
    let savePassword: Bool
    let usedStoredCredential: Bool
    let receiveAudio: Bool
}

/// Non-secret projection retained for an explicit Viewer file action. The
/// password is fetched from Keychain or requested from the user only after a
/// destination is selected, then consumed synchronously by the composition.
struct ViewerFileTransferConnectionContext {
    let rendezvousServer: String
    let serverPublicKey: String
    let peerID: String
    let forceRelay: Bool
    let credentialDeviceID: UUID?

    init(baseConfiguration: CoreConnectionConfig, credentialDeviceID: UUID?) {
        rendezvousServer = baseConfiguration.rendezvousServer
        serverPublicKey = baseConfiguration.serverPublicKey
        peerID = baseConfiguration.peerID
        forceRelay = baseConfiguration.forceRelay
        self.credentialDeviceID = credentialDeviceID
    }

    func configuration(password: String) -> CoreConnectionConfig {
        CoreConnectionConfig(
            rendezvousServer: rendezvousServer, serverPublicKey: serverPublicKey, peerID: peerID,
            password: password, forceRelay: forceRelay)
    }
}

enum ViewerFileTransferSelection {
    case download(destinationDirectory: URL)
    case upload(selectedURLs: [URL])
}

/// Breaks the construction cycle between the pipeline and its access-unit
/// callback while keeping backpressure recovery on the encoder callback
/// boundary. A late callback can only reach its own (possibly cancelled)
/// pipeline, never the next route stored by AppDelegate.
final class HostMediaPipelineReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var pipeline: HostMediaPipeline?

    func bind(_ pipeline: HostMediaPipeline) {
        lock.lock()
        self.pipeline = pipeline
        lock.unlock()
    }

    func recoverFromEncodedPacketDrop() {
        lock.lock()
        let pipeline = pipeline
        lock.unlock()
        pipeline?.recoverFromEncodedPacketDrop()
    }
}

extension HostMediaSubmissionDropReason {
    var telemetryReason: HostMediaDropReason {
        switch self {
        case .networkBackpressure: return .networkBackpressure
        case .reconfigure: return .reconfigure
        case .invalidFrame: return .invalidFrame
        case .shutdown: return .shutdown
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
