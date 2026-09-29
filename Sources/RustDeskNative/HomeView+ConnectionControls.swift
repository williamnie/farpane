import AppKit
import ConnectionCatalog

extension HomeView {
    func makeQuickConnectControls() -> NSStackView {
        peerField.placeholderString = "输入远端 ID"
        peerField.font = .monospacedSystemFont(ofSize: 13.5, weight: .regular)
        peerField.isBordered = false
        peerField.drawsBackground = false
        peerField.focusRingType = .none
        peerField.delegate = self
        peerField.target = self
        peerField.action = #selector(connectQuickly)
        peerField.setAccessibilityLabel("远端设备 ID")
        peerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 终端提示符 ❯
        let peerIcon = NSTextField(labelWithString: "❯")
        peerIcon.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        peerIcon.textColor = HomePalette.accent

        let fieldRow = NSStackView(
            views: [peerIcon, peerField], axis: .horizontal, alignment: .centerY, spacing: 8)
        fieldRow.translatesAutoresizingMaskIntoConstraints = false

        peerContainer.wantsLayer = true
        peerContainer.layer?.cornerRadius = 8
        peerContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        peerContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        peerContainer.layer?.borderWidth = 1
        peerContainer.addSubview(fieldRow)
        NSLayoutConstraint.activate([
            fieldRow.leadingAnchor.constraint(equalTo: peerContainer.leadingAnchor, constant: 12),
            fieldRow.trailingAnchor.constraint(
                equalTo: peerContainer.trailingAnchor, constant: -12),
            fieldRow.topAnchor.constraint(equalTo: peerContainer.topAnchor),
            fieldRow.bottomAnchor.constraint(equalTo: peerContainer.bottomAnchor),
        ])

        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectQuickly)

        quickSendFilesButton.bezelStyle = .rounded
        quickSendFilesButton.target = self
        quickSendFilesButton.action = #selector(sendFilesQuickly)
        quickSendFilesButton.toolTip = "连接后立即选择文件或文件夹发送到远端"
        quickSendFilesButton.setAccessibilityLabel("向远端设备发送文件")

        NSLayoutConstraint.activate([
            peerContainer.heightAnchor.constraint(equalToConstant: 34),
            connectButton.widthAnchor.constraint(equalToConstant: 82),
            connectButton.heightAnchor.constraint(equalToConstant: 34),
            quickSendFilesButton.widthAnchor.constraint(equalToConstant: 82),
            quickSendFilesButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        viewerAudioOptInSwitch.target = self
        viewerAudioOptInSwitch.action = #selector(viewerAudioOptInChanged)
        viewerAudioOptInSwitch.setAccessibilityLabel("本次连接接收远端音频")
        let viewerAudioLabel = NSTextField(labelWithString: "本次连接接收远端音频（默认关闭，断开后重置）")
        viewerAudioLabel.font = .systemFont(ofSize: 11.5)
        viewerAudioLabel.textColor = .secondaryLabelColor
        let viewerAudioRow = NSStackView(
            views: [viewerAudioLabel, NSView(), viewerAudioOptInSwitch], axis: .horizontal,
            alignment: .centerY)
        return viewerAudioRow
    }

    func makeHostIdentityControls() -> (NSStackView, NSStackView, NSStackView) {
        hostStatusDot.wantsLayer = true
        hostStatusDot.layer?.cornerRadius = 3.5
        hostStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostStatusDot.widthAnchor.constraint(equalToConstant: 7),
            hostStatusDot.heightAnchor.constraint(equalToConstant: 7),
        ])
        hostStatusLabel.font = .systemFont(ofSize: 12)
        hostStatusLabel.textColor = .secondaryLabelColor

        hostSwitch.target = self
        hostSwitch.action = #selector(hostToggleChanged)
        hostSwitch.setAccessibilityLabel("允许连接此 Mac")

        hostIDLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        hostIDLabel.textColor = HomePalette.accent
        hostIDLabel.lineBreakMode = .byTruncatingMiddle
        hostPasswordLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        hostPasswordLabel.textColor = .labelColor

        hostIDCopyButton.title = "复制"
        hostIDCopyButton.bezelStyle = .inline
        hostIDCopyButton.target = self
        hostIDCopyButton.action = #selector(copyHostID)
        hostIDCopyButton.setAccessibilityLabel("复制本机 ID")
        hostPasswordCopyButton.title = "复制"
        hostPasswordCopyButton.bezelStyle = .inline
        hostPasswordCopyButton.target = self
        hostPasswordCopyButton.action = #selector(copyHostTemporaryPassword)
        hostPasswordCopyButton.setAccessibilityLabel("复制临时密码")

        hostRevealButton.title = "显示"
        hostRevealButton.bezelStyle = .inline
        hostRevealButton.target = self
        hostRevealButton.action = #selector(revealHostPassword)
        hostRegenerateButton.title = "换一个"
        hostRegenerateButton.bezelStyle = .inline
        hostRegenerateButton.target = self
        hostRegenerateButton.action = #selector(regenerateHostPassword)

        let hostIDDetails = NSStackView(
            views: [hostIDLabel, NSView(), hostIDCopyButton], axis: .horizontal,
            alignment: .centerY, spacing: 8)
        let hostPasswordDetails = NSStackView(
            views: [
                hostPasswordLabel, NSView(), hostPasswordCopyButton, hostRevealButton,
                hostRegenerateButton,
            ], axis: .horizontal, alignment: .centerY, spacing: 8)
        hostIDLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostPasswordLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        hostCopyFeedbackLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hostCopyFeedbackLabel.textColor = HomePalette.accent
        hostCopyFeedbackLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true

        hostPermanentPasswordLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hostPermanentPasswordLabel.textColor = .secondaryLabelColor
        hostSetPermanentPasswordButton.title = "设置"
        hostSetPermanentPasswordButton.bezelStyle = .inline
        hostSetPermanentPasswordButton.target = self
        hostSetPermanentPasswordButton.action = #selector(setHostPermanentPassword)
        hostClearPermanentPasswordButton.title = "清除"
        hostClearPermanentPasswordButton.bezelStyle = .inline
        hostClearPermanentPasswordButton.target = self
        hostClearPermanentPasswordButton.action = #selector(clearHostPermanentPassword)

        let hostPermanentPasswordDetails = NSStackView(
            views: [
                hostPermanentPasswordLabel, NSView(), hostSetPermanentPasswordButton,
                hostClearPermanentPasswordButton,
            ], axis: .horizontal, alignment: .centerY, spacing: 12)
        return (hostIDDetails, hostPasswordDetails, hostPermanentPasswordDetails)
    }
}
