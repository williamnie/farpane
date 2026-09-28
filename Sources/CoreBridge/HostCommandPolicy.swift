import CoreBridgeShim
import Foundation

package enum HostCommandEnvelopePolicy {
    private static let reservedKeys = Set(["commandid", "name"])
    private static let sensitiveKeyFragments = [
        "password", "passcode", "credential", "secret", "token", "privatekey", "recoverykey",
    ]

    package static func envelope(commandName: String, commandID: String, payload: [String: Any])
        throws -> [String: Any]
    {
        guard !commandName.isEmpty, !commandID.isEmpty, commandName.utf8.count <= 128,
            commandID.utf8.count <= 128
        else { throw HostControlError.invalidCommandEnvelope }
        if normalized(commandName) == "setpermanentpassword" {
            throw HostControlError.sensitiveCommandRequiresDedicatedABI
        }
        try validateDictionary(payload, rejectReservedKeys: true)
        var envelope = payload
        envelope["commandId"] = commandID
        envelope["name"] = commandName
        return envelope
    }

    private static func validateDictionary(_ dictionary: [String: Any], rejectReservedKeys: Bool)
        throws
    {
        for (key, value) in dictionary {
            let normalizedKey = normalized(key)
            guard !rejectReservedKeys || !reservedKeys.contains(normalizedKey) else {
                throw HostControlError.invalidCommandEnvelope
            }
            guard !sensitiveKeyFragments.contains(where: normalizedKey.contains) else {
                throw HostControlError.sensitiveCommandRequiresDedicatedABI
            }
            try validateValue(value)
        }
    }

    private static func validateValue(_ value: Any) throws {
        if value is Data || value is NSData {
            throw HostControlError.sensitiveCommandRequiresDedicatedABI
        }
        if let dictionary = value as? [String: Any] {
            try validateDictionary(dictionary, rejectReservedKeys: false)
            return
        }
        if let array = value as? [Any] { for element in array { try validateValue(element) } }
    }

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// Owns the Swift half of the dedicated secret-buffer contract. The caller's
/// mutable Data is wiped after both success and thrown/error paths; Rust also
/// wipes the same bytes before its C ABI call returns.
package enum HostSecretBufferPolicy {
    package static func withMutableBytes<Result>(
        _ secret: inout Data, _ body: (UnsafeMutablePointer<UInt8>?, Int) throws -> Result
    ) rethrows -> Result {
        defer { if !secret.isEmpty { secret.resetBytes(in: 0..<secret.count) } }
        return try secret.withUnsafeMutableBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            return try body(buffer.baseAddress, buffer.count)
        }
    }
}
