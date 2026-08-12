import Foundation
import XCTest

final class HomeNavigationPermissionUIContractTests: XCTestCase {
    func testSidebarUsesRealPageSelectionAndKeepsProductActionsWired() throws {
        let sources = try sourceFiles()
        let home = sources.home

        for marker in [
            "private enum HomePage: String, CaseIterable",
            "case overview",
            "case connections",
            "case permissions",
            "case sharing",
            "private let pageTabView = NSTabView()",
            "pageTabView.tabViewType = .noTabsNoBorder",
            "pageTabView.selectTabViewItem(withIdentifier: page.rawValue)",
            "private func selectPage(_ page: HomePage)",
            "title: \"连接设备\"",
            "title: \"此 Mac\"",
            "title: \"授权与安全\"",
            "title: \"共享设置\"",
            "onHostToggle",
            "onQuickConnect",
            "onOpenSystemPermissionSettings",
            "makeOverviewPage(hostContainer: hostContainer)",
            "本机 ID、访问密码和当前入站会话都集中在这里。",
            "quickContainer = makePanel(content: quickCard)",
        ] {
            XCTAssertTrue(home.contains(marker), marker)
        }
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

    func testLocalIdentitySupportsExplicitCopyAndConnectionPaste() throws {
        let sources = try sourceFiles()
        let home = sources.home
        let app = sources.app

        for marker in [
            "hostIDCopyButton.action = #selector(copyHostID)",
            "hostPasswordCopyButton.action = #selector(copyHostTemporaryPassword)",
            "peerPasteButton.action = #selector(pastePeerID)",
            "peerPasteButton.setAccessibilityLabel(\"从剪贴板粘贴设备 ID\")",
            "let readClipboard = onReadLocalClipboardText",
            "onWriteLocalClipboardText?(value) == true",
            "showCopyFeedback(\"已复制\\(label)\", isError: false)",
            "onRevealHostPassword?()",
        ] {
            XCTAssertTrue(home.contains(marker), marker)
        }
        XCTAssertTrue(app.contains(
            "viewerPasteboardOwner.readLocalProductText()"
        ))
        XCTAssertTrue(app.contains(
            "viewerPasteboardOwner.writeLocalProductText(text)"
        ))
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
