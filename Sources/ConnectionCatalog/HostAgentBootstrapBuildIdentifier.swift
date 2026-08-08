import Foundation

enum HostAgentBootstrapBuildIdentifier {
    static func resolve(from infoDictionary: [String: Any]?) -> String? {
        guard let value = infoDictionary?["CFBundleVersion"] as? String,
              HostAgentBootstrapConfiguration.validAgentBuildID(value)
        else { return nil }
        return value
    }
}
