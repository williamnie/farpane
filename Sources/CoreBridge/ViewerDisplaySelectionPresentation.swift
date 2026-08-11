import Foundation

package struct ViewerDisplaySelectionItemPresentation: Equatable, Sendable {
    package let displayIndex: UInt32
    package let title: String
    package let selected: Bool
    package let enabled: Bool
}

package struct ViewerDisplaySelectionPresentation: Equatable, Sendable {
    package let items: [ViewerDisplaySelectionItemPresentation]
    package let selectedDisplayIndex: UInt32?
    package let selectorEnabled: Bool
    package let statusText: String?
    package let statusIsError: Bool
}

package enum ViewerDisplaySelectionPresentationPolicy {
    package static func project(
        _ snapshot: ViewerDisplaySelectionInputSnapshot
    ) -> ViewerDisplaySelectionPresentation {
        guard !snapshot.stopped, let catalog = snapshot.catalog else {
            return ViewerDisplaySelectionPresentation(
                items: [],
                selectedDisplayIndex: nil,
                selectorEnabled: false,
                statusText: "正在读取远端显示器…",
                statusIsError: false
            )
        }
        guard catalog.status == .available else {
            return ViewerDisplaySelectionPresentation(
                items: [],
                selectedDisplayIndex: nil,
                selectorEnabled: false,
                statusText: "远端显示器不可用",
                statusIsError: false
            )
        }

        let items = catalog.entries.map { entry in
            ViewerDisplaySelectionItemPresentation(
                displayIndex: entry.displayIndex,
                title: itemTitle(entry),
                selected: entry.displayIndex == catalog.selectedDisplayIndex,
                enabled: entry.online
            )
        }
        let hasSelectableItem = items.contains(where: \.enabled)
        if snapshot.pendingRequest != nil {
            return ViewerDisplaySelectionPresentation(
                items: items,
                selectedDisplayIndex: catalog.selectedDisplayIndex,
                selectorEnabled: false,
                statusText: "正在切换显示器…",
                statusIsError: false
            )
        }
        if let failure = snapshot.failure {
            return ViewerDisplaySelectionPresentation(
                items: items,
                selectedDisplayIndex: catalog.selectedDisplayIndex,
                selectorEnabled: snapshot.controlAvailable && hasSelectableItem,
                statusText: failureText(failure),
                statusIsError: true
            )
        }
        guard snapshot.controlAvailable else {
            return ViewerDisplaySelectionPresentation(
                items: items,
                selectedDisplayIndex: catalog.selectedDisplayIndex,
                selectorEnabled: false,
                statusText: "正在等待远端控制权限…",
                statusIsError: false
            )
        }
        if snapshot.inputQuiesced {
            return ViewerDisplaySelectionPresentation(
                items: items,
                selectedDisplayIndex: catalog.selectedDisplayIndex,
                selectorEnabled: hasSelectableItem,
                statusText: "请重新选择显示器以恢复远程控制",
                statusIsError: true
            )
        }
        return ViewerDisplaySelectionPresentation(
            items: items,
            selectedDisplayIndex: catalog.selectedDisplayIndex,
            selectorEnabled: hasSelectableItem,
            statusText: nil,
            statusIsError: false
        )
    }

    private static func itemTitle(_ entry: CoreDisplayCatalogEntry) -> String {
        let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "显示器 \(Int(entry.displayIndex) + 1)"
        let base = trimmed.isEmpty ? fallback : String(trimmed.prefix(48))
        guard entry.online else { return "\(base)（离线）" }
        return "\(base) · \(entry.width)×\(entry.height)"
    }

    private static func failureText(
        _ failure: ViewerDisplaySelectionInputFailure
    ) -> String {
        switch failure {
        case .admissionRejected:
            return "显示器切换请求未被接受，请重试"
        case .terminal(.catalogChanged):
            return "显示器列表已变化，请重新选择"
        case .terminal(.connectionClosed):
            return "连接已变化，重连后请重新选择"
        case .terminal(.remoteSelectionDrift):
            return "远端未切换到所选显示器，请重试"
        case .terminal(.none):
            return "显示器切换失败，请重试"
        }
    }
}
