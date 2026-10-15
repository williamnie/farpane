import AppKit

enum ViewerWindowSizing {
    static func frame(
        remoteSize: NSSize, currentFrame: NSRect, visibleFrame: NSRect, decorationSize: NSSize,
        backingScale: CGFloat
    ) -> NSRect? {
        let available = NSSize(
            width: visibleFrame.width - decorationSize.width,
            height: visibleFrame.height - decorationSize.height)
        guard remoteSize.width.isFinite, remoteSize.height.isFinite, remoteSize.width > 0,
            remoteSize.height > 0, available.width > 0, available.height > 0, backingScale.isFinite,
            backingScale > 0
        else { return nil }

        // 优先按本机物理像素一比一显示；小画面保持可操作的窗口，超大画面等比缩小。
        let minimumScale = max(
            max(0, 720 - decorationSize.width) / remoteSize.width,
            max(0, 480 - decorationSize.height) / remoteSize.height)
        let scale = min(
            max(1 / backingScale, minimumScale),
            min(available.width / remoteSize.width, available.height / remoteSize.height))
        let size = NSSize(
            width: min(visibleFrame.width, remoteSize.width * scale + decorationSize.width),
            height: min(visibleFrame.height, remoteSize.height * scale + decorationSize.height))
        return NSRect(
            x: min(
                max(currentFrame.midX - size.width / 2, visibleFrame.minX),
                visibleFrame.maxX - size.width),
            y: min(
                max(currentFrame.midY - size.height / 2, visibleFrame.minY),
                visibleFrame.maxY - size.height), width: size.width, height: size.height)
    }
}

@MainActor final class ViewerWindowSizer: NSObject {
    private weak var window: NSWindow?
    private var remoteSize: NSSize?
    private var appliedRemoteSize: NSSize?
    private var fullscreenTransition = false

    deinit { NotificationCenter.default.removeObserver(self) }

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        NotificationCenter.default.removeObserver(self)
        self.window = window
        fullscreenTransition = false
        guard let window else { return }
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
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(
                self, selector: #selector(resizeIfNeeded), name: name, object: window)
        }
        resizeIfNeeded()
    }

    func updateRemoteSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        remoteSize = NSSize(width: width, height: height)
        resizeIfNeeded()
    }

    @objc private func beginFullscreenTransition() { fullscreenTransition = true }

    @objc private func endFullscreenTransition() {
        fullscreenTransition = false
        resizeIfNeeded()
    }

    @objc private func resizeIfNeeded() {
        guard let window, let remoteSize, remoteSize != appliedRemoteSize, !fullscreenTransition,
            !window.styleMask.contains(.fullScreen), !window.inLiveResize, !window.isMiniaturized,
            let screen = window.screen ?? NSScreen.main
        else { return }
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let decorationSize = NSSize(
            width: window.frame.width - contentRect.width,
            height: window.frame.height - contentRect.height)
        guard
            let frame = ViewerWindowSizing.frame(
                remoteSize: remoteSize, currentFrame: window.frame,
                visibleFrame: screen.visibleFrame, decorationSize: decorationSize,
                backingScale: window.backingScaleFactor)
        else { return }

        // 竖屏和超宽屏可能比旧的最小尺寸更窄或更矮，避免 AppKit 强行撑出黑边。
        window.minSize = NSSize(width: min(720, frame.width), height: min(480, frame.height))
        appliedRemoteSize = remoteSize
        window.setFrame(frame, display: true)
    }
}
