import Foundation
import Security

package enum HostAgentRegistrationSigningChannel: Equatable, Sendable {
    case development
    case developerID
}

package struct HostAgentRegistrationCodeSignatureEvidence:
    Equatable,
    Sendable
{
    package let signingIdentifier: String
    package let teamIdentifier: String
    package let channel: HostAgentRegistrationSigningChannel
}

package enum HostAgentRegistrationCodeSignaturePreflightError:
    Error,
    Equatable
{
    case invalidBundleIdentity
    case codeUnavailable
    case requirementUnavailable
    case signatureMismatch
    case unsupportedChannel
    case signingInformationUnavailable
}

/// Read-only code-signing gate for future SMAppService registration. It
/// validates the whole app bundle against fixed Apple-issued requirements and
/// returns only bounded identity evidence, never certificates or raw errors.
package enum HostAgentRegistrationCodeSignaturePreflight {
    package static let expectedSigningIdentifier =
        "io.rustdesknative.viewer"
    package static let expectedTeamIdentifier = "3J43F8H829"

    package static let productRequirement = """
    identifier "io.rustdesknative.viewer" and anchor apple generic and \
    certificate leaf[subject.OU] = "3J43F8H829"
    """
    private static let developmentRequirement = """
    \(productRequirement) and \
    certificate 1[field.1.2.840.113635.100.6.2.1] exists
    """
    private static let developerIDRequirement = """
    \(productRequirement) and \
    certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
    certificate leaf[field.1.2.840.113635.100.6.1.13] exists
    """
    private static let validationFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate
    )

    package static func inspectMainBundle()
        throws -> HostAgentRegistrationCodeSignatureEvidence
    {
        do {
            _ = try HostAgentRegistrationBundlePreflight.inspectMainBundle()
        } catch {
            throw HostAgentRegistrationCodeSignaturePreflightError
                .invalidBundleIdentity
        }
        return try inspectValidatedBundle(at: Bundle.main.bundleURL)
    }

    package static func inspectValidatedBundle(at bundleURL: URL)
        throws -> HostAgentRegistrationCodeSignatureEvidence
    {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode
        else {
            throw HostAgentRegistrationCodeSignaturePreflightError
                .codeUnavailable
        }

        guard try satisfies(productRequirement, code: staticCode) else {
            throw HostAgentRegistrationCodeSignaturePreflightError
                .signatureMismatch
        }

        let channel: HostAgentRegistrationSigningChannel
        if try satisfies(developerIDRequirement, code: staticCode) {
            channel = .developerID
        } else if try satisfies(developmentRequirement, code: staticCode) {
            channel = .development
        } else {
            throw HostAgentRegistrationCodeSignaturePreflightError
                .unsupportedChannel
        }

        var information: CFDictionary?
        let informationFlags = SecCSFlags(
            rawValue: kSecCSSigningInformation
        )
        guard SecCodeCopySigningInformation(
            staticCode,
            informationFlags,
            &information
        ) == errSecSuccess,
        let dictionary = information as? [String: Any],
        let signingIdentifier = dictionary[
            kSecCodeInfoIdentifier as String
        ] as? String,
        signingIdentifier == expectedSigningIdentifier,
        let teamIdentifier = dictionary[
            kSecCodeInfoTeamIdentifier as String
        ] as? String,
        teamIdentifier == expectedTeamIdentifier
        else {
            throw HostAgentRegistrationCodeSignaturePreflightError
                .signingInformationUnavailable
        }

        return HostAgentRegistrationCodeSignatureEvidence(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            channel: channel
        )
    }

    private static func satisfies(
        _ source: String,
        code: SecStaticCode
    ) throws -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            source as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement
        else {
            throw HostAgentRegistrationCodeSignaturePreflightError
                .requirementUnavailable
        }
        return SecStaticCodeCheckValidity(
            code,
            validationFlags,
            requirement
        ) == errSecSuccess
    }
}
