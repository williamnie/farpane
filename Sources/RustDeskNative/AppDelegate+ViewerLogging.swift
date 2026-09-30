import AppKit
import VideoPipeline

extension AppDelegate {
    func recordViewerLog(_ event: ViewerSessionLiveLog.Event) {
        guard let metrics else { return }
        viewerSessionLog?.record(event, metrics: metrics, coreGeneration: viewerCoreGeneration)
    }

    func stopViewerSessionLog() {
        if let metrics {
            viewerSessionLog?.finish(metrics: metrics, coreGeneration: viewerCoreGeneration)
        }
        viewerSessionLog = nil
    }

    @objc func openDiagnosticLogs(_ sender: Any?) {
        let directory = ViewerSessionLiveLog.defaultDirectoryURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            if let viewerChrome {
                viewerChrome.updateState("无法打开日志目录", isError: true)
            } else {
                homeErrorText = "无法打开日志目录"
                refreshHomeUI()
            }
        }
    }
}
