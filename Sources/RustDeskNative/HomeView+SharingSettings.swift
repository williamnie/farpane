import AppKit
import ConnectionCatalog

extension HomeView {
    var clipboardControls:
        [(
            control: NSSwitch, preference: HostClipboardPreference, title: String,
            value: KeyPath<HostHomeSnapshot, Bool>
        )]
    {
        [
            (hostClipboardReadSwitch, .textRead, "允许远端读取本机剪贴板", \.clipboardReadEnabled),
            (hostClipboardWriteSwitch, .textWrite, "允许远端写入本机剪贴板", \.clipboardWriteEnabled),
            (
                hostClipboardRichTextReadSwitch, .richTextRead, "允许远端读取本机富文本",
                \.clipboardRichTextReadEnabled
            ),
            (
                hostClipboardRichTextWriteSwitch, .richTextWrite, "允许远端写入本机富文本",
                \.clipboardRichTextWriteEnabled
            ),
            (hostClipboardImageReadSwitch, .imageRead, "允许远端读取本机图片", \.clipboardImageReadEnabled),
            (
                hostClipboardImageWriteSwitch, .imageWrite, "允许远端写入图片到本机",
                \.clipboardImageWriteEnabled
            ),
        ]
    }

    func makeClipboardSettings() -> NSStackView {
        let headings = [
            "小型文本（最多 64 KiB）", "富文本 RTF/HTML（每种最多 1 MiB）", "图片（RGBA/PNG 最多 128 MiB，SVG 最多 4 MiB）",
        ]
        var views: [NSView] = []
        var rows: [NSView] = []
        for (index, entry) in clipboardControls.enumerated() {
            if index.isMultiple(of: 2) {
                let heading = NSTextField(labelWithString: headings[index / 2])
                heading.font = .systemFont(ofSize: 11)
                heading.textColor = .tertiaryLabelColor
                views.append(heading)
            }
            let row = makeToggleRow(
                entry.control, title: entry.title, action: #selector(hostClipboardToggleChanged(_:))
            )
            views.append(row)
            rows.append(row)
        }
        let stack = NSStackView(views: views, axis: .vertical, alignment: .leading, spacing: 5)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    func makeToggleRow(_ control: NSSwitch, title: String, action: Selector) -> NSStackView {
        control.target = self
        control.action = action
        control.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return NSStackView(
            views: [label, NSView(), control], axis: .horizontal, alignment: .centerY)
    }

    func makeFileTransferSettings() -> NSStackView {
        let hostFileTransferToggleRow = makeToggleRow(
            hostFileTransferSwitch, title: "允许远端发送文件到本机",
            action: #selector(hostFileTransferToggleChanged))

        hostFileTransferReceiveRootLabel.font = .systemFont(ofSize: 11)
        hostFileTransferReceiveRootLabel.textColor = .tertiaryLabelColor
        hostFileTransferReceiveRootLabel.lineBreakMode = .byTruncatingMiddle
        hostFileTransferReceiveRootButton.bezelStyle = .inline
        hostFileTransferReceiveRootButton.target = self
        hostFileTransferReceiveRootButton.action = #selector(chooseHostFileTransferReceiveRoot)
        hostFileTransferReceiveRootButton.setAccessibilityLabel("选择 FarPane Receive 接收文件夹的位置")
        let hostFileTransferRootRow = NSStackView(
            views: [hostFileTransferReceiveRootLabel, NSView(), hostFileTransferReceiveRootButton],
            axis: .horizontal, alignment: .centerY)

        let hostFileTransferSettings = NSStackView(
            views: [hostFileTransferToggleRow, hostFileTransferRootRow], axis: .vertical,
            alignment: .leading, spacing: 5)
        for view in [hostFileTransferToggleRow, hostFileTransferRootRow] {
            view.widthAnchor.constraint(equalTo: hostFileTransferSettings.widthAnchor).isActive =
                true
        }
        return hostFileTransferSettings
    }

    func makeAudioSettings() -> NSStackView {
        let hostAudioToggleRow = makeToggleRow(
            hostAudioSwitch, title: "允许远端接收本机音频", action: #selector(hostAudioToggleChanged))
        hostAudioInputPopup.target = self
        hostAudioInputPopup.action = #selector(hostAudioInputSelectionChanged)
        hostAudioInputPopup.setAccessibilityLabel("选择远程音频输入设备")
        hostAudioInputRefreshButton.title = "刷新"
        hostAudioInputRefreshButton.bezelStyle = .inline
        hostAudioInputRefreshButton.target = self
        hostAudioInputRefreshButton.action = #selector(refreshHostAudioInputs)
        hostAudioInputRefreshButton.setAccessibilityLabel("刷新音频输入设备")
        let hostAudioInputLabel = NSTextField(labelWithString: "音频输入")
        hostAudioInputLabel.font = .systemFont(ofSize: 12)
        hostAudioInputLabel.textColor = .secondaryLabelColor
        let hostAudioInputRow = NSStackView(
            views: [
                hostAudioInputLabel, NSView(), hostAudioInputPopup, hostAudioInputRefreshButton,
            ], axis: .horizontal, alignment: .centerY)
        hostAudioInputStatusLabel.font = .systemFont(ofSize: 11)
        hostAudioInputStatusLabel.textColor = .tertiaryLabelColor
        hostMicrophoneAuthorizationLabel.font = .systemFont(ofSize: 11)
        hostMicrophoneAuthorizationLabel.textColor = .tertiaryLabelColor
        let hostAudioSettings = NSStackView(
            views: [
                hostAudioToggleRow, hostAudioInputRow, hostAudioInputStatusLabel,
                hostMicrophoneAuthorizationLabel,
            ], axis: .vertical, alignment: .leading, spacing: 5)
        for view in [
            hostAudioToggleRow, hostAudioInputRow, hostAudioInputStatusLabel,
            hostMicrophoneAuthorizationLabel,
        ] { view.widthAnchor.constraint(equalTo: hostAudioSettings.widthAnchor).isActive = true }
        return hostAudioSettings
    }
}
