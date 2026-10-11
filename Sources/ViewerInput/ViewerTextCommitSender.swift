import CoreBridge

public enum ViewerTextCommitSender {
    public static func send(
        _ text: String, ubuntuPasteCompatibility: Bool, sendText: (String) -> Int32,
        sendKey: (CoreKeyEvent) -> Int32
    ) -> Int32 {
        let textStatus = sendText(text)
        guard textStatus == 0, ubuntuPasteCompatibility,
            text.unicodeScalars.contains(where: { !$0.isASCII })
        else { return textStatus }

        // 文本与快捷键进入同一会话输入队列，先由远端处理文本，再补发粘贴。
        let downStatus = sendKey(
            CoreKeyEvent(key: .character("v"), isDown: true, modifiers: [.control, .shift]))
        // 即使按下失败也尝试释放，避免半个快捷键残留。
        let upStatus = sendKey(CoreKeyEvent(key: .character("v"), isDown: false))
        return downStatus == 0 ? upStatus : downStatus
    }
}
