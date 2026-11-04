import Foundation

/// 仅描述已结束的本机任务，不授予文件读写权限。
package struct HostFileTransferCompletion: Equatable, Sendable {
    package let receiving: Bool
    package let directory: URL?
    package let hasSkippedFiles: Bool

    package init(document: [String: Any]) throws {
        guard Set(document.keys) == Set(["receiving", "directory", "hasSkippedFiles"]),
            let receiving = HostAgentXPCWireEventContract.strictBool(document["receiving"]),
            let skipped = HostAgentXPCWireEventContract.strictBool(document["hasSkippedFiles"]),
            let directory = document["directory"] as? String, directory.utf8.count <= 4096,
            !directory.contains("\0"), receiving ? directory.hasPrefix("/") : directory.isEmpty
        else { throw HostAgentXPCWireEventDocumentError.invalidDocument }
        self.receiving = receiving
        self.directory = receiving ? URL(fileURLWithPath: directory, isDirectory: true) : nil
        hasSkippedFiles = skipped
    }

    package var document: [String: Any] {
        [
            "receiving": receiving, "directory": directory?.path ?? "",
            "hasSkippedFiles": hasSkippedFiles,
        ]
    }
}

extension HostCoreEvent {
    package var fileTransferCompletion: HostFileTransferCompletion? {
        guard eventType == "fileTransferCompleted",
            let document = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any],
            let payload = document["payload"] as? [String: Any]
        else { return nil }
        return try? HostFileTransferCompletion(document: payload)
    }
}

extension HostAgentXPCWireEventCursorResponse {
    /// 快照刷新期间产生的完成事件必须留待下一轮读取，不能随快照游标跳过。
    package func cursorAfterResynchronization(snapshotEventID: UInt64) -> UInt64 {
        if outcome == .batch, let resumeAfterEventID { return resumeAfterEventID }
        return snapshotEventID
    }
}
