import Foundation
import XCTest

@testable import ConnectionCatalog

final class HostClipboardPreferenceTests: XCTestCase {
    func testExistingKeysRemainIndependentAndDefaultOff() throws {
        let suite = "farpane-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HostClipboardPreference.policy(from: defaults), .disabled)
        let keys = [
            "allowRemoteRead", "allowRemoteWrite", "richText.allowRemoteRead",
            "richText.allowRemoteWrite", "image.allowRemoteRead", "image.allowRemoteWrite",
        ]
        XCTAssertEqual(
            HostClipboardPreference.allCases.map(\.defaultsKey),
            keys.map { "farpane.host.clipboard." + $0 })
        for (index, preference) in HostClipboardPreference.allCases.enumerated() {
            defaults.set(true, forKey: preference.defaultsKey)
            let policy = HostClipboardPreference.policy(from: defaults)
            let values = [
                policy.allowRemoteRead, policy.allowRemoteWrite, policy.allowRemoteRichTextRead,
                policy.allowRemoteRichTextWrite, policy.allowRemoteImageRead,
                policy.allowRemoteImageWrite,
            ]
            XCTAssertEqual(values, values.indices.map { $0 == index }, preference.rawValue)
            defaults.set(false, forKey: preference.defaultsKey)
            XCTAssertEqual(HostClipboardPreference.policy(from: defaults), .disabled)
        }
    }
}
