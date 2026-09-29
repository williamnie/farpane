import AppKit
import ConnectionCatalog

extension HomeView {
    func focusQuickConnect() {
        guard selectedPage == .connections else { return }
        window?.makeFirstResponder(peerField)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === peerField {
            let hasID = !peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            connectButton.isEnabled =
                hasID && snapshot.server?.isComplete == true && snapshot.connectingPeerID == nil
        } else {
            renderDevices()
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if notification.object as? NSTextField === peerField { updatePeerFocus(true) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === peerField { updatePeerFocus(false) }
    }

    func updatePeerFocus(_ focused: Bool) {
        guard let layer = peerContainer.layer else { return }
        layer.borderColor =
            (focused
            ? HomePalette.accent.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.14))
            .cgColor
        layer.shadowColor = HomePalette.accent.cgColor
        layer.shadowOpacity = focused ? 0.25 : 0
        layer.shadowRadius = 5
        layer.shadowOffset = .zero
    }

    func performQuickAction(_ action: ((String) -> Void)?) {
        let peerID = peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerID.isEmpty, snapshot.server?.isComplete == true, snapshot.connectingPeerID == nil
        else { return }
        action?(peerID)
    }

    @objc func openServerSettings() { onOpenServerSettings?() }

    @objc func viewerAudioOptInChanged() {
        guard snapshot.connectingPeerID == nil else { return }
        onViewerAudioOptInToggle?(viewerAudioOptInSwitch.state == .on)
    }

    @objc func hostToggleChanged() { onHostToggle?(hostSwitch.state == .on) }

    @objc func hostClipboardToggleChanged(_ sender: NSSwitch) {
        guard snapshot.host.allowsClipboardPolicyChange,
            let entry = clipboardControls.first(where: { $0.control === sender })
        else { return }
        onHostClipboardToggle?(entry.preference, sender.state == .on)
    }

    @objc func hostFileTransferToggleChanged() {
        guard snapshot.host.allowsFileTransferPolicyChange else { return }
        onHostFileTransferToggle?(hostFileTransferSwitch.state == .on)
    }

    @objc func hostAudioToggleChanged() {
        guard snapshot.host.allowsAudioPolicyChange else { return }
        onHostAudioToggle?(hostAudioSwitch.state == .on)
    }

    @objc func hostAudioInputSelectionChanged() {
        guard snapshot.host.allowsAudioPolicyChange,
            let value = hostAudioInputPopup.selectedItem?.representedObject as? String
        else { return }
        onHostAudioInputSelection?(value.isEmpty ? nil : value)
    }

    func applyHostAudioInputSelection(_ host: HostHomeSnapshot) {
        hostAudioInputPopup.removeAllItems()
        hostAudioInputPopup.addItem(withTitle: "系统音频（原生）")
        hostAudioInputPopup.lastItem?.representedObject = ""
        for name in host.audioInputDeviceNames {
            hostAudioInputPopup.addItem(withTitle: name)
            hostAudioInputPopup.lastItem?.representedObject = name
        }
        if let selected = host.audioInputDeviceName, !host.audioInputDeviceNames.contains(selected)
        {
            hostAudioInputPopup.addItem(withTitle: "不可用：\(selected)")
            hostAudioInputPopup.lastItem?.representedObject = selected
        }
        let representedValue = host.audioInputDeviceName ?? ""
        if let item = hostAudioInputPopup.itemArray.first(where: {
            ($0.representedObject as? String) == representedValue
        }) {
            hostAudioInputPopup.select(item)
        }
        hostAudioInputPopup.isEnabled =
            snapshot.connectingPeerID == nil && host.allowsAudioPolicyChange
        hostAudioInputRefreshButton.isEnabled =
            snapshot.connectingPeerID == nil && host.allowsAudioPolicyChange
        if let selected = host.audioInputDeviceName {
            hostAudioInputStatusLabel.stringValue =
                host.audioInputDeviceAvailable ? "音频输入：\(selected)" : "已选设备不可用或名称不唯一；不会回退系统音频"
            hostAudioInputStatusLabel.textColor =
                host.audioInputDeviceAvailable ? .tertiaryLabelColor : .systemOrange
        } else {
            hostAudioInputStatusLabel.stringValue = "音频来源：系统音频（原生）"
            hostAudioInputStatusLabel.textColor = .tertiaryLabelColor
        }
    }

    @objc func refreshHostAudioInputs() {
        guard snapshot.host.allowsAudioPolicyChange else { return }
        onRefreshHostAudioInputs?()
    }

    @objc func chooseHostFileTransferReceiveRoot() {
        guard snapshot.host.allowsFileTransferPolicyChange else { return }
        onChooseHostFileTransferReceiveRoot?()
    }

    @objc func revealHostPassword() { onRevealHostPassword?() }

    @objc func copyHostID() { copyToPasteboard(snapshot.host.localID, label: "本机 ID") }

    @objc func copyHostTemporaryPassword() {
        if let onCopyHostTemporaryPassword {
            onCopyHostTemporaryPassword()
            return
        }
        copyToPasteboard(snapshot.host.temporaryPassword, label: "临时密码")
    }

    func reportHostTemporaryPasswordCopy(_ succeeded: Bool) {
        showCopyFeedback(succeeded ? "已复制临时密码" : "复制失败，请重试", isError: !succeeded)
    }

    func copyToPasteboard(_ value: String, label: String) {
        guard !value.isEmpty else {
            showCopyFeedback("\(label)暂不可用", isError: true)
            return
        }
        guard onWriteLocalClipboardText?(value) == true else {
            showCopyFeedback("复制失败，请重试", isError: true)
            return
        }
        showCopyFeedback("已复制\(label)", isError: false)
    }

    func showCopyFeedback(_ text: String, isError: Bool) {
        copyFeedbackGeneration &+= 1
        let generation = copyFeedbackGeneration
        hostCopyFeedbackLabel.stringValue = text
        hostCopyFeedbackLabel.textColor = isError ? .systemOrange : HomePalette.accent
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.copyFeedbackGeneration == generation else { return }
            self.hostCopyFeedbackLabel.stringValue = ""
        }
    }

    @objc func regenerateHostPassword() { onRegenerateHostPassword?() }

    @objc func setHostPermanentPassword() { onSetHostPermanentPassword?() }

    @objc func clearHostPermanentPassword() { onClearHostPermanentPassword?() }

    @objc func approveHostConnection() {
        guard let approval = snapshot.host.pendingApproval,
            approval.enabledActions.contains(.approve), !approval.isResolving
        else { return }
        onApproveHostConnection?(approval.connectionID)
    }

    @objc func rejectHostConnection() {
        guard let approval = snapshot.host.pendingApproval,
            approval.enabledActions.contains(.reject), !approval.isResolving
        else { return }
        onRejectHostConnection?(approval.connectionID)
    }

    @objc func disableHostSessionInput() { performHostSessionAction(.disableKeyboardAndMouse) }

    @objc func disableHostSessionClipboardRead() { performHostSessionAction(.disableClipboardRead) }

    @objc func disableHostSessionClipboardWrite() {
        performHostSessionAction(.disableClipboardWrite)
    }

    @objc func disableHostSessionAudio() { performHostSessionAction(.disableSystemAudio) }

    @objc func disconnectHostSession() { performHostSessionAction(.disconnect) }

    func performHostSessionAction(_ action: HostSessionHomeAction) {
        guard let session = snapshot.host.activeSession, session.enabledActions.contains(action),
            session.pendingAction == nil
        else { return }
        switch action {
        case .disableKeyboardAndMouse: guard session.canDisableKeyboardAndMouse else { return }
        case .disableClipboardRead: guard session.canDisableClipboardRead else { return }
        case .disableClipboardWrite: guard session.canDisableClipboardWrite else { return }
        case .disableClipboard: guard session.canDisableClipboard else { return }
        case .disableSystemAudio: guard session.canDisableSystemAudio else { return }
        case .disconnect: break
        }
        onHostSessionAction?(session.connectionID, action)
    }

    @objc func retryHostCommand() {
        guard let retry = snapshot.host.commandRetry else { return }
        onRetryHostCommand?(retry.connectionID)
    }

    @objc func filterChanged() { renderDevices() }
}
