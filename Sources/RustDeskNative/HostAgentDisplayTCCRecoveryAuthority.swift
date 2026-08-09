import ApplicationServices
import CoreBridge
import CoreGraphics
import Foundation

/// Non-prompting macOS adapter for H5 wake environment validation. It never
/// requests TCC access or presents UI from the background HostAgent.
final class HostAgentDisplayTCCRecoveryAuthority: @unchecked Sendable {
    private let owner: HostAgentDisplayTCCRecoveryOwner

    init(owner: HostAgentDisplayTCCRecoveryOwner) {
        self.owner = owner
    }

    static func makeProduct() -> HostAgentDisplayTCCRecoveryAuthority {
        HostAgentDisplayTCCRecoveryAuthority(
            owner: HostAgentDisplayTCCRecoveryOwner(
                operations: HostAgentDisplayTCCRecoveryOperations(
                    enumerateDisplays: { @Sendable in
                        enumerateActiveDisplays()
                    },
                    observePermissions: { @Sendable in
                        observePermissionsWithoutPrompt()
                    }
                )
            )
        )
    }

    func snapshot() -> HostAgentDisplayTCCRecoveryState {
        owner.snapshot()
    }

    @discardableResult
    func reenumerateDisplays() -> Bool {
        owner.reenumerateDisplays()
    }

    @discardableResult
    func revalidatePermissions() -> Bool {
        owner.revalidatePermissions()
    }

    func cancel() {
        owner.cancel()
    }

    private static func enumerateActiveDisplays()
        -> [HostAgentRecoveryDisplay]?
    {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0
        else { return nil }
        var displayIDs = [CGDirectDisplayID](
            repeating: 0,
            count: Int(count)
        )
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success
        else { return nil }
        let mainDisplayID = CGMainDisplayID()
        var displays: [HostAgentRecoveryDisplay] = []
        displays.reserveCapacity(Int(count))
        for displayID in displayIDs.prefix(Int(count)) {
            guard let width: UInt32 = UInt32(
                exactly: CGDisplayPixelsWide(displayID)
            ), let height: UInt32 = UInt32(
                exactly: CGDisplayPixelsHigh(displayID)
            )
            else { return nil }
            let bounds = CGDisplayBounds(displayID)
            displays.append(HostAgentRecoveryDisplay(
                canonicalID: displayID,
                pixelWidth: width,
                pixelHeight: height,
                originX: bounds.origin.x,
                originY: bounds.origin.y,
                rotationDegrees: CGDisplayRotation(displayID),
                isMain: displayID == mainDisplayID
            ))
        }
        return displays
    }

    private static func observePermissionsWithoutPrompt()
        -> HostAgentRecoveryPermissionSnapshot
    {
        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false,
        ] as CFDictionary
        return HostAgentRecoveryPermissionSnapshot(
            screenCaptureGranted: CGPreflightScreenCaptureAccess(),
            accessibilityGranted: AXIsProcessTrustedWithOptions(
                accessibilityOptions
            ),
            inputMonitoringGranted: CGPreflightListenEventAccess()
        )
    }
}
