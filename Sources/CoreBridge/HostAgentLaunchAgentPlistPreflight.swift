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
}

/// Validates the immutable product identity of the embedded LaunchAgent plist.
/// Lifecycle policy keys remain outside this preflight until registration and
/// restart semantics are implemented.
package enum HostAgentLaunchAgentPlistPreflight {
    package static let label = "io.rustdesknative.viewer.host-agent"
    package static let bundleProgram = "Contents/MacOS/RustDeskNative"
    package static let programArguments = ["RustDeskNative", "--host-agent"]
    package static let maximumPayloadBytes = 64 * 1_024

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
}
