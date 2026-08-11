import Foundation

public struct HostAgentBootstrapPublicationOutcome: Equatable, Sendable {
    public let configRevision: UInt64
    public let publicationResult: HostAgentBootstrapConfigurationPublicationResult

    public init(
        configRevision: UInt64,
        publicationResult: HostAgentBootstrapConfigurationPublicationResult
    ) {
        self.configRevision = configRevision
        self.publicationResult = publicationResult
    }
}

public enum HostAgentBootstrapPublicationCoordinatorError: Error, Equatable {
    case revisionExhausted(UInt64)
}

/// App-owned orchestration for the immutable Agent projection. The caller must
/// pass an already loaded/saved canonical catalog and a stable product build
/// identifier. This coordinator never starts HostCore or writes the catalog.
public final class HostAgentBootstrapPublicationCoordinator: @unchecked Sendable {
    private let applicationSupportURL: URL

    public init(fileManager: FileManager = .default) throws {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw HostAgentBootstrapProductLayoutError.applicationSupportUnavailable
        }
        self.applicationSupportURL = applicationSupportURL
    }

    init(applicationSupportURL: URL) {
        self.applicationSupportURL = applicationSupportURL
    }

    public func publish(
        catalog: DeviceCatalogDocument,
        agentBuildID: String,
        clipboardPolicy: HostAgentClipboardPolicy = .disabled,
        fileTransferPolicy: HostAgentFileTransferPolicy = .disabled,
        audioPolicy: HostAgentAudioPolicy = .disabled
    ) throws -> HostAgentBootstrapPublicationOutcome {
        let directoryURL = try HostAgentBootstrapProductDirectoryPreparer.prepare(
            applicationSupportURL: applicationSupportURL
        )
        let reader = HostAgentBootstrapConfigurationReader(
            directoryURL: directoryURL
        )
        let publisher = HostAgentBootstrapConfigurationPublisher(
            directoryURL: directoryURL
        )

        let existing: HostAgentBootstrapConfiguration?
        do {
            existing = try reader.load()
        } catch HostAgentBootstrapConfigurationReaderError.configurationUnavailable {
            existing = nil
        }

        let proposedRevision: UInt64
        if let existing {
            let sameRevisionDocument = try HostAgentBootstrapProjectionBuilder.build(
                catalog: catalog,
                configRevision: existing.configRevision,
                agentBuildID: agentBuildID,
                clipboardPolicy: clipboardPolicy,
                fileTransferPolicy: fileTransferPolicy,
                audioPolicy: audioPolicy
            )
            let desiredAtCurrentRevision = try HostAgentBootstrapConfiguration.decode(
                sameRevisionDocument
            )
            if desiredAtCurrentRevision == existing {
                let result = try publisher.publish(sameRevisionDocument)
                return HostAgentBootstrapPublicationOutcome(
                    configRevision: existing.configRevision,
                    publicationResult: result
                )
            }
            guard existing.configRevision
                < HostAgentBootstrapConfiguration.maximumConfigRevision
            else {
                throw HostAgentBootstrapPublicationCoordinatorError.revisionExhausted(
                    existing.configRevision
                )
            }
            proposedRevision = existing.configRevision + 1
        } else {
            proposedRevision = 1
        }

        let document = try HostAgentBootstrapProjectionBuilder.build(
            catalog: catalog,
            configRevision: proposedRevision,
            agentBuildID: agentBuildID,
            clipboardPolicy: clipboardPolicy,
            fileTransferPolicy: fileTransferPolicy,
            audioPolicy: audioPolicy
        )
        let result = try publisher.publish(document)
        return HostAgentBootstrapPublicationOutcome(
            configRevision: proposedRevision,
            publicationResult: result
        )
    }
}
