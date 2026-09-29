import CoreFoundation
import Foundation

/// 所有 XPC 信封共用严格 JSON 规则，具体消息保留自己的大小上限与错误类型。
package protocol XPCDocumentFailure: Error {
    static var invalidDocument: Self { get }
    static var documentTooLarge: Self { get }
}

package protocol XPCDocumentContract {
    associatedtype Failure: XPCDocumentFailure
    static var maximumDocumentBytes: Int { get }
}

extension XPCDocumentContract {
    package static var maximumExactJSONInteger: UInt64 { 9_007_199_254_740_991 }

    package static func decodeDocument(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw Failure.invalidDocument }
        guard data.count <= maximumDocumentBytes else { throw Failure.documentTooLarge }
        guard let value = try? JSONSerialization.jsonObject(with: data),
            let document = value as? [String: Any]
        else { throw Failure.invalidDocument }
        return document
    }

    package static func encodeDocument(_ document: [String: Any]) throws -> Data {
        let data = try encodePayload(document)
        guard data.count <= maximumDocumentBytes else { throw Failure.documentTooLarge }
        return data
    }

    package static func encodePayload(_ payload: Any) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch { throw Failure.invalidDocument }
    }

    /// JSON 布尔值、负数、小数和超过 IEEE-754 精确整数范围的数均拒绝。
    package static func strictUInt64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(maximumExactJSONInteger),
            value.rounded(.towardZero) == value
        else { return nil }
        return number.uint64Value
    }

    package static func strictInt(_ value: Any?) -> Int? {
        guard let unsigned = strictUInt64(value), unsigned <= UInt64(Int.max) else { return nil }
        return Int(unsigned)
    }

    package static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    package static func validTimestamp(_ value: UInt64) -> Bool {
        value > 0 && value <= maximumExactJSONInteger
    }
}
