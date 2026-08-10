import Foundation

public enum HostAgentBootstrapProjectionBuilderError: Error, Equatable {
    case unsupportedCatalogSchema(Int)
    case serverUnavailable
    case invalidProjection
}

public enum HostAgentBootstrapProjectionBuilder {
    public static func build(
        catalog: DeviceCatalogDocument,
        configRevision: UInt64,
        agentBuildID: String,
        clipboardPolicy: HostAgentClipboardPolicy = .disabled
    ) throws -> Data {
        guard catalog.schemaVersion == DeviceCatalogDocument.currentSchemaVersion else {
            throw HostAgentBootstrapProjectionBuilderError.unsupportedCatalogSchema(
                catalog.schemaVersion
            )
        }
        guard let server = catalog.server else {
            throw HostAgentBootstrapProjectionBuilderError.serverUnavailable
        }

        let document: [String: Any] = [
            "schemaVersion": HostAgentBootstrapConfiguration.currentSchemaVersion,
            "configRevision": NSNumber(value: configRevision),
            "agentBuildID": agentBuildID,
            "server": [
                "rendezvousServer": server.rendezvousServer,
                "serverPublicKey": server.serverPublicKey,
            ],
            "clipboard": [
                "allowRemoteRead": clipboardPolicy.allowRemoteRead,
                "allowRemoteWrite": clipboardPolicy.allowRemoteWrite,
            ],
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: document,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            _ = try HostAgentBootstrapConfiguration.decode(data)
            return data
        } catch {
            throw HostAgentBootstrapProjectionBuilderError.invalidProjection
        }
    }
}
