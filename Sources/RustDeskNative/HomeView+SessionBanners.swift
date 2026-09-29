import AppKit
import ConnectionCatalog

extension HomeView {
    func configureSessionBanner() {
        hostSessionContainer.wantsLayer = true
        hostSessionContainer.layer?.cornerRadius = 9
        hostSessionContainer.layer?.backgroundColor =
            NSColor.systemBlue.withAlphaComponent(0.07).cgColor
        hostSessionContainer.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.4).cgColor
        hostSessionContainer.layer?.borderWidth = 1
        hostSessionContainer.isHidden = true

        hostSessionTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hostSessionTitleLabel.textColor = .labelColor
        hostSessionIdentityLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        hostSessionIdentityLabel.textColor = .labelColor
        hostSessionContextLabel.font = .systemFont(ofSize: 11.5)
        hostSessionContextLabel.textColor = .secondaryLabelColor
        hostSessionCapabilityLabel.font = .systemFont(ofSize: 11.5)
        hostSessionCapabilityLabel.textColor = .secondaryLabelColor

        hostDisableInputButton.title = "停止键鼠控制"
        hostDisableInputButton.bezelStyle = .rounded
        hostDisableInputButton.target = self
        hostDisableInputButton.action = #selector(disableHostSessionInput)
        hostDisableInputButton.setAccessibilityLabel("停止当前会话的键盘与鼠标控制")
        hostDisableClipboardReadButton.title = "停止远端读取"
        hostDisableClipboardReadButton.bezelStyle = .rounded
        hostDisableClipboardReadButton.target = self
        hostDisableClipboardReadButton.action = #selector(disableHostSessionClipboardRead)
        hostDisableClipboardReadButton.setAccessibilityLabel("停止当前会话读取本机剪贴板")
        hostDisableClipboardWriteButton.title = "停止远端写入"
        hostDisableClipboardWriteButton.bezelStyle = .rounded
        hostDisableClipboardWriteButton.target = self
        hostDisableClipboardWriteButton.action = #selector(disableHostSessionClipboardWrite)
        hostDisableClipboardWriteButton.setAccessibilityLabel("停止当前会话写入本机剪贴板")
        hostDisableAudioButton.title = "停止系统音频"
        hostDisableAudioButton.bezelStyle = .rounded
        hostDisableAudioButton.target = self
        hostDisableAudioButton.action = #selector(disableHostSessionAudio)
        hostDisableAudioButton.setAccessibilityLabel("停止当前会话的系统音频")
        hostDisconnectButton.title = "断开连接"
        hostDisconnectButton.bezelStyle = .rounded
        hostDisconnectButton.contentTintColor = .systemRed
        hostDisconnectButton.target = self
        hostDisconnectButton.action = #selector(disconnectHostSession)
        hostDisconnectButton.setAccessibilityLabel("断开当前远程会话")

        let hostSessionButtons = NSStackView(
            views: [
                NSView(), hostDisableInputButton, hostDisableClipboardReadButton,
                hostDisableClipboardWriteButton, hostDisableAudioButton, hostDisconnectButton,
            ], axis: .horizontal, alignment: .centerY, spacing: 8)
        let hostSessionStack = NSStackView(
            views: [
                hostSessionTitleLabel, hostSessionIdentityLabel, hostSessionContextLabel,
                hostSessionCapabilityLabel, hostSessionButtons,
            ], axis: .vertical, alignment: .leading, spacing: 5)
        for view in [
            hostSessionTitleLabel, hostSessionIdentityLabel, hostSessionContextLabel,
            hostSessionCapabilityLabel, hostSessionButtons,
        ] { view.widthAnchor.constraint(equalTo: hostSessionStack.widthAnchor).isActive = true }
        hostSessionContainer.addSubview(hostSessionStack)
        hostSessionStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostSessionStack.leadingAnchor.constraint(
                equalTo: hostSessionContainer.leadingAnchor, constant: 12),
            hostSessionStack.trailingAnchor.constraint(
                equalTo: hostSessionContainer.trailingAnchor, constant: -12),
            hostSessionStack.topAnchor.constraint(
                equalTo: hostSessionContainer.topAnchor, constant: 10),
            hostSessionStack.bottomAnchor.constraint(
                equalTo: hostSessionContainer.bottomAnchor, constant: -10),
        ])
    }

    func configureApprovalBanner() {
        hostApprovalContainer.wantsLayer = true
        hostApprovalContainer.layer?.cornerRadius = 9
        hostApprovalContainer.layer?.backgroundColor =
            NSColor.systemOrange.withAlphaComponent(0.08).cgColor
        hostApprovalContainer.layer?.borderColor =
            NSColor.systemOrange.withAlphaComponent(0.45).cgColor
        hostApprovalContainer.layer?.borderWidth = 1
        hostApprovalContainer.isHidden = true

        hostApprovalTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hostApprovalTitleLabel.textColor = .labelColor
        hostApprovalIdentityLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        hostApprovalIdentityLabel.textColor = .labelColor
        hostApprovalContextLabel.font = .systemFont(ofSize: 11.5)
        hostApprovalContextLabel.textColor = .secondaryLabelColor
        hostApprovalCapabilityLabel.font = .systemFont(ofSize: 11.5)
        hostApprovalCapabilityLabel.textColor = .secondaryLabelColor
        hostApprovalExpiryLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        hostApprovalExpiryLabel.textColor = .systemOrange

        hostApproveButton.title = "允许一次"
        hostApproveButton.bezelStyle = .rounded
        hostApproveButton.target = self
        hostApproveButton.action = #selector(approveHostConnection)
        hostApproveButton.setAccessibilityLabel("允许远程连接一次")
        hostRejectButton.title = "拒绝"
        hostRejectButton.bezelStyle = .rounded
        hostRejectButton.target = self
        hostRejectButton.action = #selector(rejectHostConnection)
        hostRejectButton.setAccessibilityLabel("拒绝远程连接")

        let hostApprovalButtons = NSStackView(
            views: [NSView(), hostRejectButton, hostApproveButton], axis: .horizontal,
            alignment: .centerY, spacing: 8)
        let hostApprovalStack = NSStackView(
            views: [
                hostApprovalTitleLabel, hostApprovalIdentityLabel, hostApprovalContextLabel,
                hostApprovalCapabilityLabel, hostApprovalExpiryLabel, hostApprovalButtons,
            ], axis: .vertical, alignment: .leading, spacing: 5)
        for view in [
            hostApprovalTitleLabel, hostApprovalIdentityLabel, hostApprovalContextLabel,
            hostApprovalCapabilityLabel, hostApprovalExpiryLabel, hostApprovalButtons,
        ] { view.widthAnchor.constraint(equalTo: hostApprovalStack.widthAnchor).isActive = true }
        hostApprovalContainer.addSubview(hostApprovalStack)
        hostApprovalStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostApprovalStack.leadingAnchor.constraint(
                equalTo: hostApprovalContainer.leadingAnchor, constant: 12),
            hostApprovalStack.trailingAnchor.constraint(
                equalTo: hostApprovalContainer.trailingAnchor, constant: -12),
            hostApprovalStack.topAnchor.constraint(
                equalTo: hostApprovalContainer.topAnchor, constant: 10),
            hostApprovalStack.bottomAnchor.constraint(
                equalTo: hostApprovalContainer.bottomAnchor, constant: -10),
        ])
    }
}
