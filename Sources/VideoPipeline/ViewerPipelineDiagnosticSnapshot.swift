import Foundation

/// 仅包含聚合数值，不包含画面、地址、设备标识或凭据。
package struct ViewerPipelineDiagnosticSnapshot: Codable, Sendable {
    package let receivedFPS: Double
    package let presentedFPS: Double
    package let receivedPackets: Int
    package let receivedBytes: UInt64
    package let decodedFrames: Int
    package let presentedFrames: Int
    package let videoReceiveAgeMS: Double?
    package let presentationAgeMS: Double?
    package let coreMetricsAgeMS: Double?
    package let networkDelayMS: Int?
    package let targetBitrate: UInt64
    package let packetSequenceGaps: UInt64
    package let decodeErrors: Int
    package let lastDecodeErrorStatus: Int32?
    package let decoderResets: Int
    package let keyframeRequests: Int
    package let droppedFrames: Int
    package let referenceFrameDrops: Int
    package let decoderQueueDepth: Int
    package let rendererQueueDepth: Int
}
