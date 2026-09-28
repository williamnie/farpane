import AppKit
import ApplicationServices
import ConnectionCatalog
import CoreBridge
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import MetalKit
import VideoPipeline
import ViewerInput

extension AppDelegate {
    func handleViewerFileTransferProductEvent(
        _ event: ViewerFileTransferProductEvent, sessionEpoch: UInt64
    ) {
        guard viewerFileTransferComposition?.snapshot().sessionEpoch == sessionEpoch else { return }
        switch event {
        case .connectionReady: viewerChrome?.updateState("文件传输通道已就绪", isError: false)
        case .connectionFailed(_, let failure):
            viewerFileTransferActiveTransferID = nil
            viewerFileTransferActiveDirection = nil
            viewerChrome?.updateFileTransferAction(active: false)
            viewerChrome?.setFileTransferAvailable(false)
            viewerChrome?.updateState(viewerFileTransferProductFailureText(failure), isError: true)
        case .transfer(let transferEvent): handleViewerFileTransferSessionEvent(transferEvent)
        }
    }

    func handleViewerFileTransferSessionEvent(_ event: ViewerFileTransferSessionEvent) {
        switch event {
        case .manifestRequested(_, _, let transferID):
            guard transferID == viewerFileTransferActiveTransferID else { return }
            viewerChrome?.updateState("正在读取远端文件清单…", isError: false)
        case .progress(let progress):
            guard progress.transferID == viewerFileTransferActiveTransferID else { return }
            let direction: ViewerFileTransferActionDirection =
                progress.direction == .upload ? .upload : .download
            guard direction == viewerFileTransferActiveDirection else { return }
            viewerChrome?.updateFileTransferAction(
                active: true, cancellable: !progress.phase.isTerminal, direction: direction)
            let verb = direction == .upload ? "发送" : "接收"
            viewerChrome?.updateState(
                "正在\(verb)文件（\(progress.filesCompleted)/\(progress.totalFiles)）", isError: false)
        case .fileCommitted(_, let transferID, let fileNumber):
            guard transferID == viewerFileTransferActiveTransferID else { return }
            viewerChrome?.updateState("已安全接收第 \(fileNumber + 1) 个文件", isError: false)
        case .finished(_, let transferID, let outcome):
            guard transferID == viewerFileTransferActiveTransferID else { return }
            let direction = viewerFileTransferActiveDirection ?? .download
            let verb = direction == .upload ? "发送" : "接收"
            viewerFileTransferActiveTransferID = nil
            viewerFileTransferActiveDirection = nil
            viewerChrome?.updateFileTransferAction(active: false, direction: direction)
            switch outcome {
            case .completed: viewerChrome?.updateState("文件\(verb)完成", isError: false)
            case .cancelled: viewerChrome?.updateState("文件\(verb)已取消", isError: false)
            case .failed(let failure):
                viewerChrome?.updateState(
                    "文件\(verb)失败：\(viewerFileTransferSessionFailureText(failure))", isError: true)
            }
            viewerChrome?.setFileTransferAvailable(rearmViewerFileTransferComposition())
        }
    }

    func viewerFileTransferProductFailureText(_ failure: ViewerFileTransferProductFailure) -> String
    {
        switch failure {
        case .coreUnavailable: "文件传输组件不可用"
        case .authenticationRejected: "文件传输认证失败"
        case .connectionClosed: "文件传输连接已断开"
        case .protocolViolation: "文件传输通道协议异常"
        }
    }

    func viewerFileTransferSessionFailureText(_ failure: ViewerFileTransferSessionFailure) -> String
    {
        switch failure {
        case .manifest(let failure): "远端文件清单\(viewerFileTransferFailureText(failure))"
        case .receive(let failure):
            switch failure {
            case .protocolViolation: "接收协议异常"
            case .localIO: "本地写入失败"
            case .durabilityUnconfirmed: "本地落盘未确认"
            case .connectionClosed: "连接已断开"
            case .remote(let failure): "远端\(coreFileTransferFailureText(failure))"
            }
        case .coreCommandRejected: "传输命令未被接受"
        case .protocolViolation: "传输协议异常"
        case .connectionClosed: "连接已断开"
        }
    }

    func viewerFileTransferFailureText(_ failure: ViewerFileTransferFailure) -> String {
        switch failure {
        case .rejected: "被拒绝"
        case .unavailable: "不可用"
        case .protocolViolation: "协议异常"
        case .localIO: "本地读写失败"
        case .connectionClosed: "连接已断开"
        }
    }

    func coreFileTransferFailureText(_ failure: CoreFileTransferFailure) -> String {
        switch failure {
        case .none: "返回了无效失败状态"
        case .rejected: "拒绝接收"
        case .unavailable: "接收服务不可用"
        case .protocolViolation: "报告协议异常"
        case .localIO: "报告读写失败"
        case .connectionClosed: "已断开连接"
        }
    }
}
