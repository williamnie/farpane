import CoreFoundation
import Foundation

public enum HostAgentBootstrapConfigurationError: Error, Equatable {
    case documentTooLarge
    case unsupportedSchema(Int)
    case invalidDocument
}

public struct HostAgentClipboardPolicy: Equatable, Sendable {
    public static let disabled = Self(
        allowRemoteRead: false,
        allowRemoteWrite: false
    )

    public let allowRemoteRead: Bool
    public let allowRemoteWrite: Bool

    public init(allowRemoteRead: Bool, allowRemoteWrite: Bool) {
        self.allowRemoteRead = allowRemoteRead
        self.allowRemoteWrite = allowRemoteWrite
    }
}

/// Immutable, non-secret input that must be validated before HostAgent may
/// switch the Rust config namespace or create HostCore. Disk ownership,
/// atomic publication and the single-writer lease are separate later gates.
public struct HostAgentBootstrapConfiguration: Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let maximumDocumentBytes = 64 * 1_024
    public static let maximumConfigRevision: UInt64 = 9_007_199_254_740_991

    public let schemaVersion: Int
    public let configRevision: UInt64
    public let agentBuildID: String
    public let rendezvousServer: String
    public let serverPublicKey: String
    public let clipboardPolicy: HostAgentClipboardPolicy

    /// These namespace components are product-owned constants, never values
    /// accepted from disk or an environment variable.
    public let hostConfigAppName = "FarPaneHost"
    public let hostConfigOrganization = "io.rustdesknative"

    private init(
        schemaVersion: Int,
        configRevision: UInt64,
        agentBuildID: String,
        rendezvousServer: String,
        serverPublicKey: String,
        clipboardPolicy: HostAgentClipboardPolicy
    ) {
        self.schemaVersion = schemaVersion
        self.configRevision = configRevision
        self.agentBuildID = agentBuildID
        self.rendezvousServer = rendezvousServer
        self.serverPublicKey = serverPublicKey
        self.clipboardPolicy = clipboardPolicy
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else {
            throw HostAgentBootstrapConfigurationError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentBootstrapConfigurationError.documentTooLarge
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HostAgentBootstrapConfigurationError.invalidDocument
        }
        guard let document = value as? [String: Any],
              let schemaValue = strictUInt64(document["schemaVersion"]),
              schemaValue <= UInt64(Int.max)
        else { throw HostAgentBootstrapConfigurationError.invalidDocument }

        let schemaVersion = Int(schemaValue)
        guard schemaVersion == 1 || schemaVersion == currentSchemaVersion else {
            throw HostAgentBootstrapConfigurationError.unsupportedSchema(schemaVersion)
        }
        let expectedKeys: Set<String> = schemaVersion == 1
            ? ["schemaVersion", "configRevision", "agentBuildID", "server"]
            : [
                "schemaVersion", "configRevision", "agentBuildID", "server",
                "clipboard",
            ]
        guard Set(document.keys) == expectedKeys else {
            throw HostAgentBootstrapConfigurationError.invalidDocument
        }
        guard let configRevision = strictUInt64(document["configRevision"]),
              (1...maximumConfigRevision).contains(configRevision),
              let agentBuildID = document["agentBuildID"] as? String,
              validAgentBuildID(agentBuildID),
              let server = document["server"] as? [String: Any],
              Set(server.keys) == Set(["rendezvousServer", "serverPublicKey"]),
              let rendezvousServer = server["rendezvousServer"] as? String,
              validNetworkValue(rendezvousServer, maximumUTF8Bytes: 1_024),
              let serverPublicKey = server["serverPublicKey"] as? String,
              validNetworkValue(serverPublicKey, maximumUTF8Bytes: 8_192)
        else { throw HostAgentBootstrapConfigurationError.invalidDocument }

        let clipboardPolicy: HostAgentClipboardPolicy
        if schemaVersion == 1 {
            clipboardPolicy = .disabled
        } else {
            guard let clipboard = document["clipboard"] as? [String: Any],
                  Set(clipboard.keys) == Set([
                      "allowRemoteRead", "allowRemoteWrite",
                  ]),
                  let allowRemoteRead = strictBool(
                      clipboard["allowRemoteRead"]
                  ),
                  let allowRemoteWrite = strictBool(
                      clipboard["allowRemoteWrite"]
                  )
            else { throw HostAgentBootstrapConfigurationError.invalidDocument }
            clipboardPolicy = HostAgentClipboardPolicy(
                allowRemoteRead: allowRemoteRead,
                allowRemoteWrite: allowRemoteWrite
            )
        }

        return Self(
            schemaVersion: schemaVersion,
            configRevision: configRevision,
            agentBuildID: agentBuildID,
            rendezvousServer: rendezvousServer,
            serverPublicKey: serverPublicKey,
            clipboardPolicy: clipboardPolicy
        )
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    static func strictUInt64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double >= 0,
              double <= Double(maximumConfigRevision),
              double.rounded(.towardZero) == double else { return nil }
        return number.uint64Value
    }

    static func validAgentBuildID(_ value: String) -> Bool {
        validToken(value, maximumUTF8Bytes: 128)
    }

    private static func validToken(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        validString(value, maximumUTF8Bytes: maximumUTF8Bytes)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
                    || ".-_+".unicodeScalars.contains($0)
            }
    }

    private static func validNetworkValue(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> Bool {
        validString(value, maximumUTF8Bytes: maximumUTF8Bytes)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
    }

    private static func validString(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumUTF8Bytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}
