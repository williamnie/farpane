import CoreBridgeShim
import Foundation

extension Optional where Wrapped == Data {
    func withOptionalUnsafeBytes<T>(_ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        guard let data = self else { return body(nil, 0) }
        return data.withUnsafeBytes { bytes in
            body(bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
    }
}
