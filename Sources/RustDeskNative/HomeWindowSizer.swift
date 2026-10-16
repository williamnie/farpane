import AppKit

@MainActor final class HomeWindowSizer: NSObject {
    nonisolated static let defaultContentSize = NSSize(width: 1060, height: 720)

    private weak var window: NSWindow?
    private var contentSize = defaultContentSize
    private var isShowingHome = false
    private var fullscreenTransition = false
    private var restorationPending = false

    deinit { NotificationCenter.default.removeObserver(self) }

    func showHome(in window: NSWindow) {
        rememberHomeSize()
        attach(to: window)
        isShowingHome = true
        restorationPending = true
        restoreIfNeeded()
    }

    func leaveHome() {
        rememberHomeSize()
        isShowingHome = false
        restorationPending = false
    }

    private func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        NotificationCenter.default.removeObserver(self)
        self.window = window
        fullscreenTransition = false
        let center = NotificationCenter.default
        for name in [
            NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
        ] {
            center.addObserver(
                self, selector: #selector(beginFullscreenTransition), name: name, object: window)
        }
        for name in [
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
        ] {
            center.addObserver(
                self, selector: #selector(endFullscreenTransition), name: name, object: window)
        }
    }

    private func rememberHomeSize() {
        guard isShowingHome, !restorationPending, !fullscreenTransition, let window,
            !window.styleMask.contains(.fullScreen)
        else { return }
        // 只保存首页的普通窗口尺寸，远程画面和全屏尺寸不能覆盖它。
        contentSize = window.contentRect(forFrameRect: window.frame).size
    }

    @objc private func beginFullscreenTransition() {
        rememberHomeSize()
        fullscreenTransition = true
    }

    @objc private func endFullscreenTransition() {
        fullscreenTransition = false
        restoreIfNeeded()
    }

    private func restoreIfNeeded() {
        guard isShowingHome, restorationPending, !fullscreenTransition, let window,
            !window.styleMask.contains(.fullScreen)
        else { return }
        window.setContentSize(contentSize)
        window.center()
        restorationPending = false
    }
}
