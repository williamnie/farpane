import CoreFoundation
import Foundation

package enum HostAgentLaunchAgentPlistPreflightError: Error, Equatable {
    case payloadTooLarge
    case malformedPropertyList
    case forbiddenConfiguration
    case invalidLabel
    case invalidBundleProgram
    case invalidProgramArguments
    case invalidMachServices
    case invalidLifecyclePolicy
}

/// Validates the complete immutable embedded LaunchAgent declaration. The job
/// is Aqua-only, restarts only after an actual crash, and otherwise returns to
/// Mach-service demand after a clean stop.
package enum HostAgentLaunchAgentPlistPreflight {
    package static let label = "io.rustdesknative.viewer.host-agent"
    package static let bundleProgram = "Contents/MacOS/RustDeskNative"
    package static let programArguments = ["RustDeskNative", "--host-agent"]
    package static let maximumPayloadBytes = 64 * 1_024
    package static let sessionType = "Aqua"
    package static let throttleInterval = 10
    package static let exitTimeOut = 10

    private static let allowedKeys: Set<String> = [
        "Label",
        "BundleProgram",
        "ProgramArguments",
        "MachServices",
        "LimitLoadToSessionType",
        "KeepAlive",
        "ThrottleInterval",
        "ExitTimeOut",
    ]

    private static let forbiddenKeys: Set<String> = [
        "Program",
        "UserName",
        "GroupName",
    ]

    package static func validate(_ data: Data) throws {
        guard data.count <= maximumPayloadBytes else {
            throw HostAgentLaunchAgentPlistPreflightError.payloadTooLarge
        }

        let decoded: Any
        do {
            decoded = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw HostAgentLaunchAgentPlistPreflightError.malformedPropertyList
        }

        guard let propertyList = decoded as? [String: Any] else {
            throw HostAgentLaunchAgentPlistPreflightError.malformedPropertyList
        }
        guard forbiddenKeys.isDisjoint(with: propertyList.keys) else {
            throw HostAgentLaunchAgentPlistPreflightError.forbiddenConfiguration
        }
        guard propertyList.keys.allSatisfy(allowedKeys.contains) else {
            throw HostAgentLaunchAgentPlistPreflightError.forbiddenConfiguration
        }
        guard propertyList["Label"] as? String == label else {
            throw HostAgentLaunchAgentPlistPreflightError.invalidLabel
        }
        guard propertyList["BundleProgram"] as? String == bundleProgram else {
            throw HostAgentLaunchAgentPlistPreflightError.invalidBundleProgram
        }
        guard propertyList["ProgramArguments"] as? [String] == programArguments else {
            throw HostAgentLaunchAgentPlistPreflightError.invalidProgramArguments
        }
        guard hasExactMachService(propertyList["MachServices"]) else {
            throw HostAgentLaunchAgentPlistPreflightError.invalidMachServices
        }
        guard Set(propertyList.keys) == allowedKeys,
              propertyList["LimitLoadToSessionType"] as? String == sessionType,
              hasExactKeepAlive(propertyList["KeepAlive"]),
              propertyList["ThrottleInterval"] as? Int == throttleInterval,
              propertyList["ExitTimeOut"] as? Int == exitTimeOut
        else {
            throw HostAgentLaunchAgentPlistPreflightError.invalidLifecyclePolicy
        }
    }

    private static func hasExactMachService(_ value: Any?) -> Bool {
        guard
            let services = value as? [String: Any],
            services.count == 1,
            let enabled = services[label]
        else {
            return false
        }

        return CFGetTypeID(enabled as CFTypeRef) == CFBooleanGetTypeID()
            && (enabled as? Bool) == true
    }

    private static func hasExactKeepAlive(_ value: Any?) -> Bool {
        guard let policy = value as? [String: Any],
              policy.count == 1,
              let crashed = policy["Crashed"]
        else {
            return false
        }
        return CFGetTypeID(crashed as CFTypeRef) == CFBooleanGetTypeID()
            && (crashed as? Bool) == true
    }
}
