import AppKit

enum ViewerTextInputPreferences {
    private static func key(for deviceID: UUID) -> String {
        "viewer.ubuntu-paste-compatibility.v1.\(deviceID.uuidString)"
    }

    static func isEnabled(deviceID: UUID?, defaults: UserDefaults = .standard) -> Bool {
        guard let deviceID else { return false }
        return defaults.bool(forKey: key(for: deviceID))
    }

    static func setEnabled(_ enabled: Bool, deviceID: UUID, defaults: UserDefaults = .standard) {
        if enabled {
            defaults.set(true, forKey: key(for: deviceID))
        } else {
            defaults.removeObject(forKey: key(for: deviceID))
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleUbuntuPasteCompatibility(_:)) else { return true }
        menuItem.state = viewerView?.ubuntuPasteCompatibilityEnabled == true ? .on : .off
        return viewerView != nil && coreClient != nil && viewerRecoveryDeviceID != nil
    }

    @objc func toggleUbuntuPasteCompatibility(_ sender: NSMenuItem) {
        guard let viewerView, coreClient != nil, let deviceID = viewerRecoveryDeviceID else {
            return
        }
        let enabled = !viewerView.ubuntuPasteCompatibilityEnabled
        viewerView.ubuntuPasteCompatibilityEnabled = enabled
        ViewerTextInputPreferences.setEnabled(enabled, deviceID: deviceID)
        sender.state = enabled ? .on : .off
    }
}
