import Foundation

/// 六个方向各自持久化；单次开关只更改对应键，永不隐式开启其他格式。
package enum HostClipboardPreference: String, CaseIterable {
    case textRead = "allowRemoteRead"
    case textWrite = "allowRemoteWrite"
    case richTextRead = "richText.allowRemoteRead"
    case richTextWrite = "richText.allowRemoteWrite"
    case imageRead = "image.allowRemoteRead"
    case imageWrite = "image.allowRemoteWrite"

    package var defaultsKey: String { "farpane.host.clipboard." + rawValue }

    package static func policy(from defaults: UserDefaults) -> HostAgentClipboardPolicy {
        func enabled(_ preference: Self) -> Bool { defaults.bool(forKey: preference.defaultsKey) }
        return HostAgentClipboardPolicy(
            allowRemoteRead: enabled(.textRead), allowRemoteWrite: enabled(.textWrite),
            allowRemoteRichTextRead: enabled(.richTextRead),
            allowRemoteRichTextWrite: enabled(.richTextWrite),
            allowRemoteImageRead: enabled(.imageRead), allowRemoteImageWrite: enabled(.imageWrite))
    }
}
