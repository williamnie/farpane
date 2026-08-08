@testable import CoreBridge
import Darwin
import Foundation
import XCTest

final class HostAgentLaunchAgentAssetReaderTests: XCTestCase {
    private var fixtureRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in fixtureRoots {
            try? FileManager.default.removeItem(at: root)
        }
        fixtureRoots.removeAll()
        try super.tearDownWithError()
    }

    func testReadsOnlyTheFixedLaunchAgentAsset() throws {
        let fixture = try makeBundleFixture()
        let expected = try validPlistData()
        try expected.write(to: fixture.assetURL)
        XCTAssertEqual(chmod(fixture.assetURL.path, 0o444), 0)

        XCTAssertEqual(
            try HostAgentLaunchAgentAssetReader.readBundle(at: fixture.bundleURL),
            expected
        )
    }

    func testMissingAssetFailsClosed() throws {
        let fixture = try makeBundleFixture()

        XCTAssertThrowsError(
            try HostAgentLaunchAgentAssetReader.readBundle(at: fixture.bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentAssetReaderError,
                .unavailable
            )
        }
    }

    func testRejectsSymlinkedAssetAndDirectory() throws {
        let assetFixture = try makeBundleFixture()
        let targetURL = assetFixture.launchAgentsURL
            .appendingPathComponent("decoy.plist")
        try validPlistData().write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: assetFixture.assetURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(
            try HostAgentLaunchAgentAssetReader.readBundle(
                at: assetFixture.bundleURL
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentAssetReaderError,
                .unsafeLayout
            )
        }

        let directoryFixture = temporaryRoot()
        let bundleURL = directoryFixture.appendingPathComponent(
            "FarPane.app",
            isDirectory: true
        )
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let realLibraryURL = directoryFixture.appendingPathComponent(
            "RealLibrary",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: realLibraryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: contentsURL.appendingPathComponent("Library"),
            withDestinationURL: realLibraryURL
        )

        XCTAssertThrowsError(
            try HostAgentLaunchAgentAssetReader.readBundle(at: bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentAssetReaderError,
                .unsafeLayout
            )
        }

        let realBundleFixture = try makeBundleFixture()
        try validPlistData().write(to: realBundleFixture.assetURL)
        let bundleLinkRoot = temporaryRoot()
        try FileManager.default.createDirectory(
            at: bundleLinkRoot,
            withIntermediateDirectories: true
        )
        let bundleLinkURL = bundleLinkRoot.appendingPathComponent(
            "FarPane.app",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: bundleLinkURL,
            withDestinationURL: realBundleFixture.bundleURL
        )

        XCTAssertThrowsError(
            try HostAgentLaunchAgentAssetReader.readBundle(at: bundleLinkURL)
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentAssetReaderError,
                .unsafeLayout
            )
        }
    }

    func testRejectsHardLinkedAsset() throws {
        let fixture = try makeBundleFixture()
        try validPlistData().write(to: fixture.assetURL)
        try FileManager.default.linkItem(
            at: fixture.assetURL,
            to: fixture.launchAgentsURL.appendingPathComponent("second.plist")
        )

        XCTAssertThrowsError(
            try HostAgentLaunchAgentAssetReader.readBundle(at: fixture.bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentAssetReaderError,
                .unsafeLayout
            )
        }
    }

    func testRejectsWritableAssetOrDirectory() throws {
        let fileFixture = try makeBundleFixture()
        try validPlistData().write(to: fileFixture.assetURL)
        XCTAssertEqual(chmod(fileFixture.assetURL.path, 0o666), 0)

        XCTAssertThrowsError(
            try HostAgentLaunchAgentAssetReader.readBundle(
                at: fileFixture.bundleURL
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentAssetReaderError,
                .unsafeLayout
            )
        }

        let directoryFixture = try makeBundleFixture()
        try validPlistData().write(to: directoryFixture.assetURL)
        XCTAssertEqual(chmod(directoryFixture.launchAgentsURL.path, 0o777), 0)

        XCTAssertThrowsError(
            try HostAgentLaunchAgentAssetReader.readBundle(
                at: directoryFixture.bundleURL
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentAssetReaderError,
                .unsafeLayout
            )
        }
    }

    func testRejectsEmptyAndOversizedAsset() throws {
        let emptyFixture = try makeBundleFixture()
        try Data().write(to: emptyFixture.assetURL)

        XCTAssertThrowsError(
            try HostAgentLaunchAgentAssetReader.readBundle(
                at: emptyFixture.bundleURL
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentAssetReaderError,
                .invalidSize
            )
        }

        let oversizedFixture = try makeBundleFixture()
        let oversized = Data(
            repeating: 0x41,
            count: HostAgentLaunchAgentPlistPreflight.maximumPayloadBytes + 1
        )
        try oversized.write(to: oversizedFixture.assetURL)

        XCTAssertThrowsError(
            try HostAgentLaunchAgentAssetReader.readBundle(
                at: oversizedFixture.bundleURL
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentLaunchAgentAssetReaderError,
                .invalidSize
            )
        }
    }

    func testProductEntryHasNoPathOrDataOverride() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/CoreBridge/HostAgentLaunchAgentAssetReader.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("package static func readMainBundle()"))
        XCTAssertTrue(source.contains("Bundle.main.bundleURL"))
        XCTAssertTrue(source.contains(
            "io.rustdesknative.viewer.host-agent.plist"
        ))
        XCTAssertFalse(source.contains("ProcessInfo.processInfo.environment"))
        XCTAssertFalse(source.contains("FileManager.default.currentDirectoryPath"))
    }

    private func makeBundleFixture() throws -> (
        bundleURL: URL,
        launchAgentsURL: URL,
        assetURL: URL
    ) {
        let bundleURL = temporaryRoot().appendingPathComponent(
            "FarPane.app",
            isDirectory: true
        )
        let launchAgentsURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: launchAgentsURL,
            withIntermediateDirectories: true
        )
        for directory in [
            bundleURL,
            bundleURL.appendingPathComponent("Contents", isDirectory: true),
            bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true),
            launchAgentsURL,
        ] {
            XCTAssertEqual(chmod(directory.path, 0o755), 0)
        }
        return (
            bundleURL,
            launchAgentsURL,
            launchAgentsURL.appendingPathComponent(
                "io.rustdesknative.viewer.host-agent.plist"
            )
        )
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HostAgentLaunchAgentAssetReaderTests-\(UUID().uuidString)",
                isDirectory: true
            )
        fixtureRoots.append(root)
        return root
    }

    private func validPlistData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "io.rustdesknative.viewer.host-agent",
                "BundleProgram": "Contents/MacOS/RustDeskNative",
                "ProgramArguments": ["RustDeskNative", "--host-agent"],
                "MachServices": [
                    "io.rustdesknative.viewer.host-agent": true,
                ],
            ],
            format: .xml,
            options: 0
        )
    }
}
