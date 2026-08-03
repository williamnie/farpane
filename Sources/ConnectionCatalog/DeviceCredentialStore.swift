import Foundation
import Security

public enum DeviceCredentialStoreError: Error, Equatable {
    case lockedOrDenied
    case invalidData
    case unexpectedStatus(Int32)
}

public protocol DeviceCredentialStore: AnyObject {
    func contains(deviceID: UUID) throws -> Bool
    func read(deviceID: UUID) throws -> String?
    func upsert(_ password: String, deviceID: UUID) throws
    func delete(deviceID: UUID) throws
}

public final class KeychainDeviceCredentialStore: DeviceCredentialStore {
    public static let defaultService = "io.rustdesknative.viewer.device-password"

    private let service: String

    public init(service: String = KeychainDeviceCredentialStore.defaultService) {
        self.service = service
    }

    public func contains(deviceID: UUID) throws -> Bool {
        var query = baseQuery(deviceID: deviceID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw map(status)
        }
    }

    public func read(deviceID: UUID) throws -> String? {
        var query = baseQuery(deviceID: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
                throw DeviceCredentialStoreError.invalidData
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw map(status)
        }
    }

    public func upsert(_ password: String, deviceID: UUID) throws {
        let data = Data(password.utf8)
        let query = baseQuery(deviceID: deviceID)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw map(updateStatus) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw map(addStatus) }
    }

    public func delete(deviceID: UUID) throws {
        let status = SecItemDelete(baseQuery(deviceID: deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
    }

    private func baseQuery(deviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.uuidString,
        ]
    }

    private func map(_ status: OSStatus) -> DeviceCredentialStoreError {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable, errSecUserCanceled:
            return .lockedOrDenied
        default:
            return .unexpectedStatus(status)
        }
    }
}
