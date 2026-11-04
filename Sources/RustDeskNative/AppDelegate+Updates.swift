import AppKit

extension AppDelegate {
    @MainActor func startReleaseChecks() {
        guard !automatedRun, releaseUpdateTimer == nil else { return }
        releaseUpdateChecker.onChange = { [weak self] in self?.refreshReleaseUI() }
        releaseUpdateChecker.onManualResult = { [weak self] in self?.presentReleaseCheckResult($0) }
        refreshReleaseUI()
        releaseUpdateChecker.checkIfDue()
        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActorBackport.assumeIsolated { _ = self?.releaseUpdateChecker.checkIfDue() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        releaseUpdateTimer = timer
    }

    @MainActor func refreshReleaseUI() {
        homeView?.applyUpdateChecker(releaseUpdateChecker)
        if let update = releaseUpdateChecker.availableUpdate {
            releaseUpdateMenuItem?.title = "发现新版本 \(update.tag)…"
        } else {
            releaseUpdateMenuItem?.title = releaseUpdateChecker.isChecking ? "正在检查更新…" : "检查更新…"
        }
    }

    @objc func checkForReleaseUpdates(_ sender: Any?) {
        MainActorBackport.assumeIsolated { _ = releaseUpdateChecker.check() }
    }

    @MainActor func openReleasePage() {
        let url = releaseUpdateChecker.availableUpdate?.pageURL ?? GitHubReleaseClient.releasesPage
        NSWorkspace.shared.open(url)
    }

    @MainActor func presentReleaseCheckResult(_ result: ReleaseCheckOutcome) {
        let alert = NSAlert()
        let destination: URL
        switch result {
        case .available(let update):
            alert.messageText = "发现新版本 \(update.tag)"
            let current = releaseUpdateChecker.currentVersion ?? "未知"
            alert.informativeText =
                "当前版本：\(current)\(update.isPrerelease ? "\n这是预览版本。" : "")\n前往发布页查看更新说明并下载适用于这台 Mac 的安装包。"
            alert.addButton(withTitle: "前往下载")
            alert.addButton(withTitle: "稍后")
            destination = update.pageURL
        case .upToDate:
            alert.messageText = "已是最新可用版本"
            alert.informativeText = "当前版本 \(releaseUpdateChecker.currentVersion ?? "") 没有可用的更新。"
            alert.addButton(withTitle: "好")
            destination = GitHubReleaseClient.releasesPage
        case .failed(let message):
            alert.messageText = "无法检查更新"
            alert.informativeText = message
            alert.addButton(withTitle: "打开发布页")
            alert.addButton(withTitle: "稍后")
            destination = GitHubReleaseClient.releasesPage
        }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn, result != .upToDate {
                NSWorkspace.shared.open(destination)
            }
        }
        if let window, window.attachedSheet == nil {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
