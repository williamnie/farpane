import AppKit
import XCTest

@testable import RustDeskNative

final class ReleaseUpdateTests: XCTestCase {
    func testSemanticVersionOrderingAndInvalidTags() throws {
        let ordered = [
            "0.2.9", "v0.2.10", "0.2.13-alpha", "0.2.13-alpha.2", "0.2.13-alpha.10", "0.2.13-beta",
            "0.2.13-rc.1", "0.2.13", "0.3.0", "1.0.0",
        ]
        let versions = try ordered.map { try XCTUnwrap(ReleaseVersion($0)) }
        XCTAssertEqual(versions.sorted(), versions)
        XCTAssertEqual(ReleaseVersion("v0.2.13+build.42"), ReleaseVersion("0.2.13"))
        XCTAssertLessThan(
            try XCTUnwrap(ReleaseVersion("1.0.0-99999999999999999999999")),
            try XCTUnwrap(ReleaseVersion("1.0.0-100000000000000000000000")))
        for value in [
            "", "v", "1", "1.2", "1.2.3.4", "01.2.3", "1.2.3-", "1.2.3-01", "1.2.3-a..b", "1.2.3+",
            "1.2.3+a+b", "1.2.3/evil", "１.2.3", " 1.2.3",
        ] { XCTAssertNil(ReleaseVersion(value), value) }
    }

    func testSelectsHighestCompatibleReleaseIncludingPreviews() throws {
        let releases = [
            release("v0.2.15", assets: ["FarPane-v0.2.15-macos-x86_64.dmg"]),
            release("v0.2.19", assets: ["FarPane-0.2.19-linux-x86_64.tar.gz"]),
            release("v0.2.16", assets: ["FarPane-v0.2.13-macos-arm64.dmg"]),
            release("v0.2.18", draft: true), release("v0.2.14", prerelease: true),
            release("v0.2.9"), release("v0.2.13"), release("nightly"),
        ]
        let current = try XCTUnwrap(ReleaseVersion("0.2.13"))
        let result = try XCTUnwrap(
            ReleaseUpdate.newest(in: releases, after: current, architecture: "arm64"))
        XCTAssertEqual(result.tag, "v0.2.14")
        XCTAssertTrue(result.isPrerelease)
        XCTAssertEqual(
            result.pageURL.absoluteString,
            "https://github.com/williamnie/farpane/releases/tag/v0.2.14")
        XCTAssertEqual(
            ReleaseUpdate.newest(in: releases, after: current, architecture: "x86_64")?.tag,
            "v0.2.15")
        XCTAssertNil(
            ReleaseUpdate.newest(in: [release("v0.2.13"), release("v0.2.9")], after: current))
    }

    func testInstallerMustBeUploadedNonemptyAndMayBeUniversal() throws {
        let current = try XCTUnwrap(ReleaseVersion("0.2.13"))
        let incomplete = GitHubRelease(
            tagName: "v0.2.16", draft: false, prerelease: false,
            assets: [
                .init(name: "FarPane-v0.2.16-macos-arm64.dmg", state: "new", size: 10),
                .init(name: "FarPane-v0.2.16-macos-universal.dmg", state: "uploaded", size: 0),
            ])
        let universal = release("v0.2.14", assets: ["FarPane-v0.2.14-macos-universal.dmg"])
        for architecture in ["arm64", "x86_64"] {
            XCTAssertEqual(
                ReleaseUpdate.newest(
                    in: [incomplete, universal], after: current, architecture: architecture)?.tag,
                "v0.2.14")
        }
    }

    @MainActor func testAutomaticChecksAreThrottledAndPreferencePersists() async {
        let defaults = temporaryDefaults()
        var date = Date(timeIntervalSince1970: 100_000)
        var requests = 0
        let checker = ReleaseUpdateChecker(
            currentVersion: "0.2.13", defaults: defaults, now: { date },
            fetch: {
                requests += 1
                return [self.release("v0.2.13")]
            })
        XCTAssertTrue(checker.automaticEnabled)
        await checker.checkIfDue()?.value
        XCTAssertEqual(checker.outcome, .upToDate)
        XCTAssertNil(checker.checkIfDue())
        date.addTimeInterval(6 * 60 * 60)
        await checker.checkIfDue()?.value
        XCTAssertEqual(requests, 2)
        checker.setAutomaticEnabled(false)
        date.addTimeInterval(7 * 60 * 60)
        XCTAssertNil(checker.checkIfDue())
        XCTAssertFalse(
            ReleaseUpdateChecker(currentVersion: "0.2.13", defaults: defaults).automaticEnabled)
        await checker.check()?.value
        XCTAssertEqual(requests, 3)
    }

    @MainActor func testManualRequestJoinsAutomaticCheckAndOnlyManualGetsAResultDialog() async {
        let started = expectation(description: "request started")
        var resume: CheckedContinuation<[GitHubRelease], Error>?
        var requests = 0
        let checker = ReleaseUpdateChecker(
            currentVersion: "0.2.13", defaults: temporaryDefaults(),
            fetch: {
                requests += 1
                return try await withCheckedThrowingContinuation {
                    resume = $0
                    started.fulfill()
                }
            })
        var presentations: [ReleaseCheckOutcome] = []
        checker.onManualResult = { presentations.append($0) }
        let task = checker.checkIfDue()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(checker.isChecking)
        checker.check()
        checker.check()
        resume?.resume(returning: [release("v0.2.14")])
        await task?.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(presentations, [.available(.init(tag: "v0.2.14", isPrerelease: false))])
        XCTAssertFalse(checker.isChecking)
    }

    @MainActor func testFailureRetainsKnownUpdateAndRetriesAfterAnHourWithoutAutomaticDialog() async
    {
        var date = Date(timeIntervalSince1970: 100_000)
        var fail = false
        let checker = ReleaseUpdateChecker(
            currentVersion: "0.2.13", defaults: temporaryDefaults(), now: { date },
            fetch: {
                if fail { throw URLError(.notConnectedToInternet) }
                return [self.release("v0.2.14")]
            })
        var presentations = 0
        checker.onManualResult = { _ in presentations += 1 }
        await checker.checkIfDue()?.value
        XCTAssertEqual(checker.availableUpdate?.tag, "v0.2.14")
        fail = true
        date.addTimeInterval(6 * 60 * 60)
        await checker.checkIfDue()?.value
        guard case .failed = checker.outcome else {
            return XCTFail("Network failure must not report latest")
        }
        XCTAssertEqual(checker.availableUpdate?.tag, "v0.2.14")
        XCTAssertEqual(presentations, 0)
        XCTAssertNil(checker.checkIfDue())
        fail = false
        date.addTimeInterval(60 * 60)
        await checker.checkIfDue()?.value
        XCTAssertEqual(checker.outcome, .available(.init(tag: "v0.2.14", isPrerelease: false)))
    }

    @MainActor func testMissingBundleVersionDoesNotSendAutomaticRequestsOrClaimLatest() async {
        var requests = 0
        let checker = ReleaseUpdateChecker(
            currentVersion: nil, defaults: temporaryDefaults(),
            fetch: {
                requests += 1
                return []
            })
        XCTAssertNil(checker.checkIfDue())
        checker.check()
        guard case .failed = checker.outcome else {
            return XCTFail("Missing version must be explained")
        }
        XCTAssertEqual(requests, 0)
    }

    @MainActor func testNoCompatibleInstallersDoesNotClaimLatest() async {
        let checker = ReleaseUpdateChecker(
            currentVersion: "0.2.13", defaults: temporaryDefaults(), fetch: { [] })
        await checker.check()?.value
        guard case .failed = checker.outcome else {
            return XCTFail("An empty release list cannot establish the latest available version")
        }
        XCTAssertNil(checker.availableUpdate)
    }

    @MainActor func testStoppingDiscardsInFlightResult() async {
        let started = expectation(description: "request started")
        var resume: CheckedContinuation<[GitHubRelease], Error>?
        let checker = ReleaseUpdateChecker(
            currentVersion: "0.2.13", defaults: temporaryDefaults(),
            fetch: {
                try await withCheckedThrowingContinuation {
                    resume = $0
                    started.fulfill()
                }
            })
        let task = checker.check()
        await fulfillment(of: [started], timeout: 2)
        checker.stop()
        resume?.resume(returning: [release("v0.2.14")])
        await task?.value
        XCTAssertNil(checker.outcome)
        XCTAssertNil(checker.availableUpdate)
    }

    @MainActor func testUpdateControlsRouteActionsAndNoticeFitsMinimumWindow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let view = HomeView()
        window.contentView = view
        let checker = ReleaseUpdateChecker(
            currentVersion: "0.2.13", defaults: temporaryDefaults(),
            fetch: { [self.release("v0.2.14")] })
        view.applyUpdateChecker(checker)
        XCTAssertTrue(view.updateNoticeButton.isHidden)
        var toggles: [Bool] = []
        var checks = 0
        var opens = 0
        view.onAutomaticUpdatesToggle = { toggles.append($0) }
        view.onCheckForUpdates = { checks += 1 }
        view.onOpenReleasePage = { opens += 1 }
        view.automaticUpdatesSwitch.state = .off
        view.automaticUpdatesChanged()
        view.checkUpdatesButton.performClick(nil)
        await checker.check(manual: false)?.value
        view.applyUpdateChecker(checker)
        view.updateNoticeButton.performClick(nil)
        XCTAssertEqual(toggles, [false])
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(view.updateNoticeButton.isHidden)
        view.layoutSubtreeIfNeeded()
        let notice = view.updateNoticeButton.convert(view.updateNoticeButton.bounds, to: view)
        XCTAssertGreaterThan(notice.width, 0)
        XCTAssertTrue(view.bounds.contains(notice))
        view.sidebarButtons[.sharing]?.performClick(nil)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.updateStatusLabel.bounds.width, 200)
        if let destination = ProcessInfo.processInfo.environment["FARPANE_UPDATE_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: destination))
        }
        window.contentView = nil
    }

    private func temporaryDefaults() -> UserDefaults {
        let suite = "FarPaneUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func release(
        _ tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String]? = nil
    ) -> GitHubRelease {
        GitHubRelease(
            tagName: tag, draft: draft, prerelease: prerelease,
            assets: (assets ?? ["FarPane-\(tag)-macos-universal.dmg"]).map {
                .init(name: $0, state: "uploaded", size: 100)
            })
    }
}
