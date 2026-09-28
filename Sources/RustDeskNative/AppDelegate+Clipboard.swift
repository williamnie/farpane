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
    func handleViewerClipboardText(
        _ text: String, coreGeneration: UInt64, attemptID: UUID?, clipboardSessionEpoch: UInt64?
    ) {
        guard coreGeneration == viewerCoreGeneration else { return }
        if let attemptID, activeAttemptID != attemptID { return }
        guard let clipboardSessionEpoch, clipboardSessionEpoch == viewerClipboardSessionEpoch else {
            return
        }
        viewerPasteboardOwner.receiveRemoteText(text, sessionEpoch: clipboardSessionEpoch)
    }

    func handleViewerClipboardRichText(
        _ payload: CoreClipboardRichTextPayload, coreGeneration: UInt64, attemptID: UUID?,
        clipboardSessionEpoch: UInt64?
    ) {
        guard coreGeneration == viewerCoreGeneration else { return }
        if let attemptID, activeAttemptID != attemptID { return }
        guard let clipboardSessionEpoch, clipboardSessionEpoch == viewerClipboardSessionEpoch else {
            return
        }
        viewerPasteboardOwner.receiveRemoteRichText(payload, sessionEpoch: clipboardSessionEpoch)
    }

    func handleViewerClipboardImage(
        _ payload: CoreClipboardImagePayload, coreGeneration: UInt64, attemptID: UUID?,
        clipboardSessionEpoch: UInt64?
    ) {
        guard coreGeneration == viewerCoreGeneration else { return }
        if let attemptID, activeAttemptID != attemptID { return }
        guard let clipboardSessionEpoch, clipboardSessionEpoch == viewerClipboardSessionEpoch else {
            return
        }
        viewerPasteboardOwner.receiveRemoteImage(payload, sessionEpoch: clipboardSessionEpoch)
    }

    func stopViewerClipboard() {
        guard let sessionEpoch = viewerClipboardSessionEpoch else { return }
        viewerClipboardSessionEpoch = nil
        viewerPasteboardOwner.stop(sessionEpoch: sessionEpoch)
    }
}
