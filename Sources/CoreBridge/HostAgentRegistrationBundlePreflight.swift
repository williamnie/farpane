import Foundation

package enum HostAgentRegistrationBundlePreflightError: Error, Equatable {
    case invalidLocation
    case invalidBundleIdentifier
    case invalidPackageType
    case invalidExecutable
    case invalidBuildIdentifier
}

package struct HostAgentRegistrationBundleIdentity: Equatable, Sendable {
    package let buildIdentifier: String

    package init(buildIdentifier: String) {
        self.buildIdentifier = buildIdentifier
    }
}

/// Registration preflight for the immutable, non-signing portion of the main
/// app identity. Code-signing, Team ID and notarization remain independent
/// evidence and must pass before a future registration mutation.
package enum HostAgentRegistrationBundlePreflight {
    package static let expectedBundlePath = "/Applications/FarPane.app"
    package static let expectedBundleIdentifier = "io.rustdesknative.viewer"
    package static let expectedExecutable = "RustDeskNative"

    private static let expectedPackageType = "APPL"
    private static let maximumBuildIdentifierBytes = 128
    private static let buildIdentifierPunctuation = ".-_+".unicodeScalars

    package static func inspectMainBundle()
        throws -> HostAgentRegistrationBundleIdentity
    {
        let bundleURL = Bundle.main.bundleURL
        return try validate(
            bundleURL: bundleURL,
            resolvedBundleURL: bundleURL.resolvingSymlinksInPath(),
            infoDictionary: Bundle.main.infoDictionary
        )
    }

    package static func validate(
        bundleURL: URL,
        resolvedBundleURL: URL,
        infoDictionary: [String: Any]?
    ) throws -> HostAgentRegistrationBundleIdentity {
        guard exactProductLocation(bundleURL),
              exactProductLocation(resolvedBundleURL)
        else {
            throw HostAgentRegistrationBundlePreflightError.invalidLocation
        }
        guard infoDictionary?["CFBundleIdentifier"] as? String
            == expectedBundleIdentifier
        else {
            throw HostAgentRegistrationBundlePreflightError
                .invalidBundleIdentifier
        }
        guard infoDictionary?["CFBundlePackageType"] as? String
            == expectedPackageType
        else {
            throw HostAgentRegistrationBundlePreflightError.invalidPackageType
        }
        guard infoDictionary?["CFBundleExecutable"] as? String
            == expectedExecutable
        else {
            throw HostAgentRegistrationBundlePreflightError.invalidExecutable
        }
        guard let buildIdentifier = infoDictionary?["CFBundleVersion"] as? String,
              validBuildIdentifier(buildIdentifier)
        else {
            throw HostAgentRegistrationBundlePreflightError
                .invalidBuildIdentifier
        }

        return HostAgentRegistrationBundleIdentity(
            buildIdentifier: buildIdentifier
        )
    }

    private static func exactProductLocation(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.host == nil || url.host == ""
        else {
            return false
        }
        return url.standardizedFileURL.path == expectedBundlePath
    }

    package static func validBuildIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumBuildIdentifierBytes
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || buildIdentifierPunctuation.contains($0)
        }
    }
}
