import Darwin
import Foundation

package enum HostAgentXPCPeerAdmissionStatus: Equatable, Sendable {
    case eligible
    case invalidProcess
    case differentUser
    case localAuthorityUnavailable
    case differentAuditSession
    case executableUnavailable
    case invalidExecutable
}

struct HostAgentXPCExecutableIdentity: Equatable, Sendable {
    let reportedPath: String
    let resolvedPath: String
}

/// Evaluates kernel-owned NSXPC peer metadata before any exported interface is
/// installed. The listener-level signing requirement remains an independent,
/// earlier gate; both must pass before a future runtime may accept a peer.
package enum HostAgentXPCPeerAdmissionGate {
    package static let expectedExecutablePath =
        HostAgentRegistrationBundlePreflight.expectedBundlePath
        + "/Contents/MacOS/"
        + HostAgentRegistrationBundlePreflight.expectedExecutable

    private static let executablePathBufferBytes = 4 * 1_024

    /// Product entry point. It is valid only for a connection delivered to an
    /// NSXPCListener delegate; inactive or synthetic connections are API misuse.
    package static func assess(_ connection: NSXPCConnection)
        -> HostAgentXPCPeerAdmissionStatus
    {
        guard let localAuditSessionIdentifier =
            currentAuditSessionIdentifier()
        else {
            return .localAuthorityUnavailable
        }

        return assess(
            processIdentifier: connection.processIdentifier,
            effectiveUserIdentifier: connection.effectiveUserIdentifier,
            auditSessionIdentifier: connection.auditSessionIdentifier,
            localProcessIdentifier: getpid(),
            localEffectiveUserIdentifier: geteuid(),
            localAuditSessionIdentifier: localAuditSessionIdentifier,
            resolveExecutable: resolveExecutable(processIdentifier:)
        )
    }

    static func assess(
        processIdentifier: pid_t,
        effectiveUserIdentifier: uid_t,
        auditSessionIdentifier: au_asid_t,
        localProcessIdentifier: pid_t,
        localEffectiveUserIdentifier: uid_t,
        localAuditSessionIdentifier: au_asid_t,
        resolveExecutable: (pid_t) -> HostAgentXPCExecutableIdentity?
    ) -> HostAgentXPCPeerAdmissionStatus {
        guard processIdentifier > 1,
              processIdentifier != localProcessIdentifier
        else {
            return .invalidProcess
        }
        guard effectiveUserIdentifier == localEffectiveUserIdentifier else {
            return .differentUser
        }
        guard auditSessionIdentifier > 0,
              localAuditSessionIdentifier > 0,
              auditSessionIdentifier == localAuditSessionIdentifier
        else {
            return .differentAuditSession
        }
        guard let executable = resolveExecutable(processIdentifier) else {
            return .executableUnavailable
        }
        guard executable.reportedPath == expectedExecutablePath,
              executable.resolvedPath == expectedExecutablePath
        else {
            return .invalidExecutable
        }
        return .eligible
    }

    static func currentAuditSessionIdentifier() -> au_asid_t? {
        var information = auditinfo_addr()
        let result = getaudit_addr(
            &information,
            Int32(MemoryLayout<auditinfo_addr>.size)
        )
        guard result == 0, information.ai_asid > 0 else {
            return nil
        }
        return information.ai_asid
    }

    static func resolveExecutable(processIdentifier: pid_t)
        -> HostAgentXPCExecutableIdentity?
    {
        guard processIdentifier > 1 else { return nil }

        var buffer = [CChar](
            repeating: 0,
            count: executablePathBufferBytes
        )
        let byteCount = proc_pidpath(
            processIdentifier,
            &buffer,
            UInt32(buffer.count)
        )
        guard byteCount > 0,
              byteCount < buffer.count,
              let path = String(validatingCString: buffer),
              !path.isEmpty,
              path.hasPrefix("/")
        else {
            return nil
        }

        let pathURL = URL(fileURLWithPath: path, isDirectory: false)
        return HostAgentXPCExecutableIdentity(
            reportedPath: path,
            resolvedPath: pathURL.resolvingSymlinksInPath().path
        )
    }
}
