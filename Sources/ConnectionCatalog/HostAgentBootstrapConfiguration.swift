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
        allowRemoteWrite: false,
        allowRemoteRichTextRead: false,
        allowRemoteRichTextWrite: false,
        allowRemoteImageRead: false,
        allowRemoteImageWrite: false
    )

    public let allowRemoteRead: Bool
    public let allowRemoteWrite: Bool
    public let allowRemoteRichTextRead: Bool
    public let allowRemoteRichTextWrite: Bool
    public let allowRemoteImageRead: Bool
    public let allowRemoteImageWrite: Bool

    public init(
        allowRemoteRead: Bool,
        allowRemoteWrite: Bool,
        allowRemoteRichTextRead: Bool = false,
        allowRemoteRichTextWrite: Bool = false,
        allowRemoteImageRead: Bool = false,
        allowRemoteImageWrite: Bool = false
    ) {
        self.allowRemoteRead = allowRemoteRead
        self.allowRemoteWrite = allowRemoteWrite
        self.allowRemoteRichTextRead = allowRemoteRichTextRead
        self.allowRemoteRichTextWrite = allowRemoteRichTextWrite
        self.allowRemoteImageRead = allowRemoteImageRead
        self.allowRemoteImageWrite = allowRemoteImageWrite
    }
}

public struct HostAgentFileTransferPolicy: Equatable, Sendable {
    public static let disabled = Self(enabled: false, receiveRoot: nil)

    public let enabled: Bool
    public let receiveRoot: String?

    public init(enabled: Bool, receiveRoot: String?) {
        self.enabled = enabled
        self.receiveRoot = receiveRoot
    }

    public static func validatedEnabled(
        receiveRoot: String
    ) -> Self? {
        guard validReceiveRoot(receiveRoot) else { return nil }
        return Self(enabled: true, receiveRoot: receiveRoot)
    }

    fileprivate static func validReceiveRoot(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              value == value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              value.hasPrefix("/"),
              value != "/"
        else { return false }
        return (value as NSString).standardizingPath == value
    }
}

public struct HostAgentAudioPolicy: Equatable, Sendable {
    public static let disabled = Self(enabled: false, inputDeviceName: nil)

    public let enabled: Bool
    public let inputDeviceName: String?

    public init(enabled: Bool, inputDeviceName: String? = nil) {
        self.enabled = enabled
        self.inputDeviceName = inputDeviceName
    }

    /// A nil input selects ScreenCaptureKit system-audio loopback. Only an
    /// explicitly selected CoreAudio input needs microphone authorization.
    public var requiresMicrophoneAuthorization: Bool {
        enabled && inputDeviceName != nil
    }

    public static func validatedEnabled(
        inputDeviceName: String?
    ) -> Self? {
        guard inputDeviceName.map(validInputDeviceName) ?? true else {
            return nil
        }
        return Self(enabled: true, inputDeviceName: inputDeviceName)
    }

    public static func validInputDeviceName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && value == value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

public struct HostAudioInputDeviceCatalog: Equatable, Sendable {
    public let uniqueNames: [String]

    public init(reportedNames: [String]) {
        let validNames = reportedNames.filter(
            HostAgentAudioPolicy.validInputDeviceName
        )
        let counts = Dictionary(
            grouping: validNames,
            by: { $0 }
        ).mapValues(\.count)
        uniqueNames = counts.compactMap { name, count in
            count == 1 ? name : nil
        }.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    public func containsUnique(_ name: String) -> Bool {
        uniqueNames.contains(name)
    }
}

/// Immutable, non-secret input that must be validated before HostAgent may
/// switch the Rust config namespace or create HostCore. Disk ownership,
/// atomic publication and the single-writer lease are separate later gates.
public struct HostAgentBootstrapConfiguration: Equatable, Sendable {
    public static let currentSchemaVersion = 7
    public static let maximumDocumentBytes = 64 * 1_024
    public static let maximumConfigRevision: UInt64 = 9_007_199_254_740_991

    public let schemaVersion: Int
    public let configRevision: UInt64
    public let agentBuildID: String
    public let rendezvousServer: String
    public let serverPublicKey: String
    public let clipboardPolicy: HostAgentClipboardPolicy
    public let fileTransferPolicy: HostAgentFileTransferPolicy
    public let audioPolicy: HostAgentAudioPolicy

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
        clipboardPolicy: HostAgentClipboardPolicy,
        fileTransferPolicy: HostAgentFileTransferPolicy,
        audioPolicy: HostAgentAudioPolicy
    ) {
        self.schemaVersion = schemaVersion
        self.configRevision = configRevision
        self.agentBuildID = agentBuildID
        self.rendezvousServer = rendezvousServer
        self.serverPublicKey = serverPublicKey
        self.clipboardPolicy = clipboardPolicy
        self.fileTransferPolicy = fileTransferPolicy
        self.audioPolicy = audioPolicy
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
        guard (1...currentSchemaVersion).contains(schemaVersion) else {
            throw HostAgentBootstrapConfigurationError.unsupportedSchema(schemaVersion)
        }
        let expectedKeys: Set<String>
        if schemaVersion == 1 {
            expectedKeys = [
                "schemaVersion", "configRevision", "agentBuildID", "server",
            ]
        } else if schemaVersion <= 4 {
            expectedKeys = [
                "schemaVersion", "configRevision", "agentBuildID", "server",
                "clipboard",
            ]
        } else if schemaVersion == 5 {
            expectedKeys = [
                "schemaVersion", "configRevision", "agentBuildID", "server",
                "clipboard", "fileTransfer",
            ]
        } else {
            expectedKeys = [
                "schemaVersion", "configRevision", "agentBuildID", "server",
                "clipboard", "fileTransfer", "audio",
            ]
        }
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
            guard let clipboard = document["clipboard"] as? [String: Any]
            else { throw HostAgentBootstrapConfigurationError.invalidDocument }
            let expectedClipboardKeys: Set<String>
            if schemaVersion == 2 {
                expectedClipboardKeys = [
                    "allowRemoteRead", "allowRemoteWrite",
                ]
            } else if schemaVersion == 3 {
                expectedClipboardKeys = [
                    "allowRemoteRead", "allowRemoteWrite",
                    "allowRemoteRichTextRead", "allowRemoteRichTextWrite",
                ]
            } else {
                expectedClipboardKeys = [
                    "allowRemoteRead", "allowRemoteWrite",
                    "allowRemoteRichTextRead", "allowRemoteRichTextWrite",
                    "allowRemoteImageRead", "allowRemoteImageWrite",
                ]
            }
            guard Set(clipboard.keys) == expectedClipboardKeys,
                  let allowRemoteRead = strictBool(
                      clipboard["allowRemoteRead"]
                  ),
                  let allowRemoteWrite = strictBool(
                      clipboard["allowRemoteWrite"]
                  )
            else { throw HostAgentBootstrapConfigurationError.invalidDocument }
            let allowRemoteRichTextRead: Bool
            let allowRemoteRichTextWrite: Bool
            if schemaVersion == 2 {
                allowRemoteRichTextRead = false
                allowRemoteRichTextWrite = false
            } else {
                guard let decodedRead = strictBool(
                    clipboard["allowRemoteRichTextRead"]
                ),
                let decodedWrite = strictBool(
                    clipboard["allowRemoteRichTextWrite"]
                ) else {
                    throw HostAgentBootstrapConfigurationError.invalidDocument
                }
                allowRemoteRichTextRead = decodedRead
                allowRemoteRichTextWrite = decodedWrite
            }
            let allowRemoteImageRead: Bool
            let allowRemoteImageWrite: Bool
            if schemaVersion <= 3 {
                allowRemoteImageRead = false
                allowRemoteImageWrite = false
            } else {
                guard let decodedRead = strictBool(
                    clipboard["allowRemoteImageRead"]
                ),
                let decodedWrite = strictBool(
                    clipboard["allowRemoteImageWrite"]
                ) else {
                    throw HostAgentBootstrapConfigurationError.invalidDocument
                }
                allowRemoteImageRead = decodedRead
                allowRemoteImageWrite = decodedWrite
            }
            clipboardPolicy = HostAgentClipboardPolicy(
                allowRemoteRead: allowRemoteRead,
                allowRemoteWrite: allowRemoteWrite,
                allowRemoteRichTextRead: allowRemoteRichTextRead,
                allowRemoteRichTextWrite: allowRemoteRichTextWrite,
                allowRemoteImageRead: allowRemoteImageRead,
                allowRemoteImageWrite: allowRemoteImageWrite
            )
        }

        let fileTransferPolicy: HostAgentFileTransferPolicy
        if schemaVersion <= 4 {
            fileTransferPolicy = .disabled
        } else {
            guard let fileTransfer = document["fileTransfer"] as? [String: Any],
                  Set(fileTransfer.keys) == Set(["enabled", "receiveRoot"]),
                  let enabled = strictBool(fileTransfer["enabled"])
            else { throw HostAgentBootstrapConfigurationError.invalidDocument }

            let receiveRootValue = fileTransfer["receiveRoot"]
            if enabled {
                guard let receiveRoot = receiveRootValue as? String,
                      let policy = HostAgentFileTransferPolicy
                        .validatedEnabled(receiveRoot: receiveRoot)
                else { throw HostAgentBootstrapConfigurationError.invalidDocument }
                fileTransferPolicy = policy
            } else {
                guard receiveRootValue is NSNull else {
                    throw HostAgentBootstrapConfigurationError.invalidDocument
                }
                fileTransferPolicy = .disabled
            }
        }

        let audioPolicy: HostAgentAudioPolicy
        if schemaVersion <= 5 {
            audioPolicy = .disabled
        } else {
            guard let audio = document["audio"] as? [String: Any],
                  Set(audio.keys) == (schemaVersion == 6
                    ? Set(["enabled"])
                    : Set(["enabled", "inputDeviceName"])),
                  let enabled = strictBool(audio["enabled"])
            else { throw HostAgentBootstrapConfigurationError.invalidDocument }
            if schemaVersion == 6 {
                audioPolicy = enabled
                    ? HostAgentAudioPolicy(enabled: true)
                    : .disabled
            } else if enabled {
                let inputValue = audio["inputDeviceName"]
                let inputDeviceName: String?
                if inputValue is NSNull {
                    inputDeviceName = nil
                } else if let name = inputValue as? String {
                    inputDeviceName = name
                } else {
                    throw HostAgentBootstrapConfigurationError.invalidDocument
                }
                guard let policy = HostAgentAudioPolicy.validatedEnabled(
                    inputDeviceName: inputDeviceName
                ) else {
                    throw HostAgentBootstrapConfigurationError.invalidDocument
                }
                audioPolicy = policy
            } else {
                guard audio["inputDeviceName"] is NSNull else {
                    throw HostAgentBootstrapConfigurationError.invalidDocument
                }
                audioPolicy = .disabled
            }
        }

        return Self(
            schemaVersion: schemaVersion,
            configRevision: configRevision,
            agentBuildID: agentBuildID,
            rendezvousServer: rendezvousServer,
            serverPublicKey: serverPublicKey,
            clipboardPolicy: clipboardPolicy,
            fileTransferPolicy: fileTransferPolicy,
            audioPolicy: audioPolicy
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
