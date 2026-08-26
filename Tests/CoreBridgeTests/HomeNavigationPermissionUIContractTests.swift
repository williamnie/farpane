import Foundation
import XCTest

final class HomeNavigationPermissionUIContractTests: XCTestCase {
    func testSidebarUsesRealPageSelectionAndKeepsProductActionsWired() throws {
        let sources = try sourceFiles()
        let home = sources.home

        for marker in [
            "private enum HomePage: String, CaseIterable",
            "case connections",
            "case permissions",
            "case sharing",
            "private let pageTabView = NSTabView()",
            "pageTabView.tabViewType = .noTabsNoBorder",
            "pageTabView.selectTabViewItem(withIdentifier: page.rawValue)",
            "private func selectPage(_ page: HomePage)",
            "HomeSidebarButtonCell(horizontalPadding: 10)",
            "title: \"设备\"",
            "title: \"授权与安全\"",
            "title: \"共享设置\"",
            "onHostToggle",
            "onQuickConnect",
            "onQuickSendFiles",
            "quickSendFilesButton",
            "onOpenSystemPermissionSettings",
            "makeHostMiniCard(title: \"本机 ID\"",
            "makeHostMiniCard(title: \"临时密码\"",
            "makeHostMiniCard(title: \"永久密码\"",
            "let hostToggleTitle = NSTextField(labelWithString: \"被控 Host\")",
            "let connectionColumn = NSStackView(views: [connectionRow, viewerAudioRow])",
            "equalTo: connectionColumn.widthAnchor",
            "let quickDivider = NSView()",
            "multiplier: 0.62",
            "hostPasswordLabel.setContentCompressionResistancePriority(.required, for: .horizontal)",
            "permissionChipsLabel.attributedStringValue = permissionChipsText(permissions)",
            "输入远端 ID 发起连接，或从最近连接快速返回。",
            "quickContainer = makePanel(content: quickCard)",
        ] {
            XCTAssertTrue(home.contains(marker), marker)
        }
        XCTAssertFalse(home.contains("case overview"))
        XCTAssertFalse(home.contains("makeOverviewPage"))
        XCTAssertFalse(home.contains("scrollToVisible"))
        XCTAssertFalse(home.contains("case localMac"))
        XCTAssertFalse(home.contains("LOCAL CONSOLE"))
        XCTAssertFalse(home.contains("NSColor.controlBackgroundColor.cgColor"))
    }

    func testPermissionModuleUsesAuthoritativeTCCReadbackAndSystemSettings() throws {
        let sources = try sourceFiles()
        let home = sources.home
        let app = sources.app

        for marker in [
            "case screenRecording",
            "case accessibility",
            "case inputMonitoring",
            "case microphone",
            "var isRequired: Bool { self != .microphone }",
            "FarPane 只读取系统返回的授权状态，不能自行授予权限。",
            "title: \"重新检测\"",
        ] {
            XCTAssertTrue(home.contains(marker), marker)
        }
        for marker in [
            "permissions: currentHomeSystemPermissions()",
            "CGPreflightScreenCaptureAccess()",
            "AXIsProcessTrustedWithOptions(",
            "CGPreflightListenEventAccess()",
            "hostMicrophoneAuthorizationAuthority.authorizationStatus()",
            "Privacy_ScreenCapture",
            "Privacy_Accessibility",
            "Privacy_ListenEvent",
            "Privacy_Microphone",
            "NSWorkspace.shared.open(url)",
            "func applicationDidBecomeActive",
            "refreshHomeUI()",
        ] {
            XCTAssertTrue(app.contains(marker), marker)
        }
    }

    func testLocalIdentitySupportsExplicitCopyAndStandardConnectionPaste() throws {
        let sources = try sourceFiles()
        let home = sources.home
        let app = sources.app

        for marker in [
            "hostIDCopyButton.action = #selector(copyHostID)",
            "hostPasswordCopyButton.action = #selector(copyHostTemporaryPassword)",
            "onWriteLocalClipboardText?(value) == true",
            "showCopyFeedback(\"已复制\\(label)\", isError: false)",
            "onCopyHostTemporaryPassword()",
            "reportHostTemporaryPasswordCopy",
        ] {
            XCTAssertTrue(home.contains(marker), marker)
        }
        XCTAssertFalse(home.contains("peerPasteButton"))
        XCTAssertFalse(home.contains("⏎ connect"))
        XCTAssertTrue(app.contains(
            "viewerPasteboardOwner.readLocalProductText()"
        ))
        XCTAssertTrue(app.contains(
            "viewerPasteboardOwner.writeLocalProductText(text)"
        ))
        XCTAssertTrue(app.contains(
            "startBackgroundPasswordOperation(.revealTemporaryPassword)"
        ))
        for marker in [
            "let editMenu = NSMenu(title: \"编辑\")",
            "action: #selector(NSText.paste(_:))",
            "keyEquivalent: \"v\"",
            "action: #selector(NSText.selectAll(_:))",
        ] {
            XCTAssertTrue(app.contains(marker), marker)
        }
    }

    private func sourceFiles() throws -> (home: String, app: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return (
            try String(
                contentsOf: root.appendingPathComponent(
                    "Sources/RustDeskNative/HomeView.swift"
                ),
                encoding: .utf8
            ),
            try String(
                contentsOf: root.appendingPathComponent(
                    "Sources/RustDeskNative/RustDeskNativeApp.swift"
                ),
                encoding: .utf8
            )
        )
    }
}
