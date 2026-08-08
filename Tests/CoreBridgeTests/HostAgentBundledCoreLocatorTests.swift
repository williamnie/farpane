@testable import CoreBridge
import Darwin
import Foundation
import XCTest

final class HostAgentBundledCoreLocatorTests: XCTestCase {
    private var fixtureRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in fixtureRoots {
            try? FileManager.default.removeItem(at: root)
        }
        fixtureRoots.removeAll()
        try super.tearDownWithError()
    }

    func testReturnsOnlyFixedPrivateFrameworksCore() throws {
        let fixture = try makeFrameworksFixture()
        let coreURL = fixture.appendingPathComponent(
            HostAgentBundledCoreLocator.coreLibraryFileName
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: coreURL.path,
            contents: Data("signed-core-placeholder".utf8)
        ))
        XCTAssertEqual(chmod(coreURL.path, 0o555), 0)

        XCTAssertEqual(
            try HostAgentBundledCoreLocator.locate(
                privateFrameworksURL: fixture
            ),
            coreURL
        )
    }

    func testProductEntryUsesBundleAuthorityWithoutFallbacks() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/CoreBridge/HostAgentBundledCoreLocator.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("public static func locate() throws -> URL"))
        XCTAssertTrue(source.contains("Bundle.main.privateFrameworksURL"))
        XCTAssertTrue(source.contains(
            "public static let coreLibraryFileName = \"liblibrustdesk.dylib\""
        ))
        XCTAssertFalse(source.contains("ProcessInfo.processInfo.environment"))
        XCTAssertFalse(source.contains("FileManager.default.currentDirectoryPath"))
    }

    func testDoesNotSearchAlternateNamesOrLocations() throws {
        let fixture = try makeFrameworksFixture()
        let decoyURL = fixture.appendingPathComponent("attacker.dylib")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: decoyURL.path,
            contents: Data("decoy".utf8)
        ))

        XCTAssertThrowsError(
            try HostAgentBundledCoreLocator.locate(
                privateFrameworksURL: fixture
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBundledCoreLocatorError,
                .coreUnavailable
            )
        }
    }

    func testRejectsSymlinkAndHardLinkedCore() throws {
        let symlinkFixture = try makeFrameworksFixture()
        let symlinkTarget = symlinkFixture.appendingPathComponent("target.dylib")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: symlinkTarget.path,
            contents: Data("target".utf8)
        ))
        try FileManager.default.createSymbolicLink(
            at: symlinkFixture.appendingPathComponent(
                HostAgentBundledCoreLocator.coreLibraryFileName
            ),
            withDestinationURL: symlinkTarget
        )
        XCTAssertThrowsError(
            try HostAgentBundledCoreLocator.locate(
                privateFrameworksURL: symlinkFixture
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBundledCoreLocatorError,
                .unsafeCoreFile
            )
        }

        let hardLinkFixture = try makeFrameworksFixture()
        let hardLinkTarget = hardLinkFixture.appendingPathComponent("target.dylib")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: hardLinkTarget.path,
            contents: Data("target".utf8)
        ))
        try FileManager.default.linkItem(
            at: hardLinkTarget,
            to: hardLinkFixture.appendingPathComponent(
                HostAgentBundledCoreLocator.coreLibraryFileName
            )
        )
        XCTAssertThrowsError(
            try HostAgentBundledCoreLocator.locate(
                privateFrameworksURL: hardLinkFixture
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBundledCoreLocatorError,
                .unsafeCoreFile
            )
        }
    }

    func testRejectsWritableOrSymlinkedFrameworksLayout() throws {
        let writableFixture = try makeFrameworksFixture()
        let coreURL = writableFixture.appendingPathComponent(
            HostAgentBundledCoreLocator.coreLibraryFileName
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: coreURL.path,
            contents: Data("core".utf8)
        ))
        XCTAssertEqual(chmod(coreURL.path, 0o777), 0)
        XCTAssertThrowsError(
            try HostAgentBundledCoreLocator.locate(
                privateFrameworksURL: writableFixture
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBundledCoreLocatorError,
                .unsafeCoreFile
            )
        }

        let realFixture = try makeFrameworksFixture()
        let symlinkRoot = temporaryRoot()
        let symlinkURL = symlinkRoot
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: realFixture
        )
        XCTAssertThrowsError(
            try HostAgentBundledCoreLocator.locate(
                privateFrameworksURL: symlinkURL
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBundledCoreLocatorError,
                .unsafeFrameworksDirectory
            )
        }
    }

    func testRejectsEmptyCoreAndWritableFrameworksDirectory() throws {
        let emptyFixture = try makeFrameworksFixture()
        let emptyCoreURL = emptyFixture.appendingPathComponent(
            HostAgentBundledCoreLocator.coreLibraryFileName
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: emptyCoreURL.path,
            contents: Data()
        ))
        XCTAssertThrowsError(
            try HostAgentBundledCoreLocator.locate(
                privateFrameworksURL: emptyFixture
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBundledCoreLocatorError,
                .unsafeCoreFile
            )
        }

        let writableFixture = try makeFrameworksFixture()
        let coreURL = writableFixture.appendingPathComponent(
            HostAgentBundledCoreLocator.coreLibraryFileName
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: coreURL.path,
            contents: Data("core".utf8)
        ))
        XCTAssertEqual(chmod(writableFixture.path, 0o777), 0)
        XCTAssertThrowsError(
            try HostAgentBundledCoreLocator.locate(
                privateFrameworksURL: writableFixture
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBundledCoreLocatorError,
                .unsafeFrameworksDirectory
            )
        }
    }

    private func makeFrameworksFixture() throws -> URL {
        let root = temporaryRoot()
        let frameworksURL = root
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: frameworksURL,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(frameworksURL.path, 0o755), 0)
        return frameworksURL
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HostAgentBundledCoreLocatorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        fixtureRoots.append(root)
        return root
    }
}
