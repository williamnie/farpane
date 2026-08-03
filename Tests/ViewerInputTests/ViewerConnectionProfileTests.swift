import Foundation
import ViewerInput
import XCTest

final class ViewerConnectionProfileTests: XCTestCase {
    func testPersistsOnlyNonPasswordConnectionSettings() throws {
        let suite = "ViewerConnectionProfileTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ViewerConnectionProfileStore(defaults: defaults)
        let profile = ViewerConnectionProfile(
            rendezvousServer: "server.example.invalid:21116",
            serverPublicKey: "public-key",
            peerID: "peer-id",
            forceRelay: true
        )

        store.save(profile)

        XCTAssertEqual(store.load(), profile)
        let persistent = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertFalse(String(describing: persistent).contains("password"))
        XCTAssertFalse(String(describing: persistent).contains("one-time-password"))

        store.clear()
        XCTAssertNil(store.load())
    }

    func testIgnoresCorruptSavedProfile() {
        let suite = "ViewerConnectionProfileTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "viewer.connection-profile.v1")

        XCTAssertNil(ViewerConnectionProfileStore(defaults: defaults).load())
    }
}
