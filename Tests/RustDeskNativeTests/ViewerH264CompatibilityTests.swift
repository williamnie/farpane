import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import CoreBridge
@testable import RustDeskNative
@testable import VideoPipeline

private final class ViewerEncodedFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: HostVideoAccessUnit?

    func store(_ frame: HostVideoAccessUnit) {
        lock.lock()
        defer { lock.unlock() }
        self.frame = frame
    }

    func read() -> HostVideoAccessUnit? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}

private final class ViewerDecodedFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func nextIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { count += 1 }
        return count
    }
}

final class ViewerH264CompatibilityTests: XCTestCase {
    func testCodecSwitchesKeepH264AndHEVCParameterSetsSeparate() throws {
        let h264 = try encodedFrame(codec: .h264)
        let hevc = try encodedFrame(codec: .hevc)
        let ready = (0..<3).map { expectation(description: "codec switch frame \($0)") }
        let counter = ViewerDecodedFrameCounter()
        let metrics = PipelineMetrics(
            inputWidth: 128, inputHeight: 128, inputFPS: 30, selectedGPU: "VideoToolbox",
            source: "viewer-codec-switch-regression")
        let decoder = LiveHEVCDecoder(metrics: metrics) { _, _ in
            let index = counter.nextIndex()
            if index < ready.count { ready[index].fulfill() }
        }
        defer { decoder.invalidate() }
        let frames: [(CoreVideoCodec, HostVideoAccessUnit, UInt32)] = [
            (.h264, h264, 1 | 4 | 8), (.h265, hevc, 1 | 2 | 4 | 8), (.h264, h264, 1 | 4 | 8),
        ]
        for (index, frame) in frames.enumerated() {
            let packet = CoreVideoPacket(
                codec: frame.0, format: .avcc, data: frame.1.data, sequence: UInt64(index + 1),
                timestampUS: UInt64(index + 1) * 33_333, flags: frame.2, width: 128, height: 128,
                display: 0, connectionEpoch: 1, displayCatalogRevision: 1)
            AppDelegate.consume(
                packet: packet, decoder: decoder, metrics: metrics, fallbackFPS: 30,
                recovery: CoreRecoveryCoordinator())
            wait(for: [ready[index]], timeout: 5)
        }
        XCTAssertEqual(metrics.snapshot().decodedFrames, 3)
        XCTAssertEqual(metrics.snapshot().decodeErrors, 0)
    }

    func testConsumesRealH264FramesInAnnexBAndAVCC() throws {
        let frame = try encodedFrame(codec: .h264)
        let parsed = try H264FramingAccessUnit(data: frame.data, framing: .avcc4)
        for framing in [H264WireFraming.annexB, .avcc4] {
            let decoded = expectation(description: "H.264 \(framing) decoded")
            let metrics = PipelineMetrics(
                inputWidth: 128, inputHeight: 128, inputFPS: 30, selectedGPU: "VideoToolbox",
                source: "h264-viewer-regression")
            let decoder = LiveHEVCDecoder(metrics: metrics) { buffer, _ in
                XCTAssertEqual(CVPixelBufferGetWidth(buffer), 128)
                XCTAssertEqual(CVPixelBufferGetHeight(buffer), 128)
                decoded.fulfill()
            }
            defer { decoder.invalidate() }
            let packet = CoreVideoPacket(
                codec: .h264, format: framing == .annexB ? .annexB : .avcc,
                data: parsed.encoded(as: framing), sequence: 1,
                timestampUS: frame.presentationTimeUS, flags: 1 | 4 | 8, width: 128, height: 128,
                display: 0, connectionEpoch: 1, displayCatalogRevision: 1)
            AppDelegate.consume(
                packet: packet, decoder: decoder, metrics: metrics, fallbackFPS: 30,
                recovery: CoreRecoveryCoordinator())
            XCTAssertEqual(metrics.snapshot().decodeErrors, 0)
            wait(for: [decoded], timeout: 5)
            XCTAssertEqual(metrics.snapshot().decodedFrames, 1)
            XCTAssertTrue(metrics.snapshot().hardwareDecodeActive)
        }
    }

    private func encodedFrame(codec: HostCompressionCodec) throws -> HostVideoAccessUnit {
        guard HostVideoEncoder.hardwareEncodingSupported(codec: codec) else {
            throw XCTSkip("required hardware encoder is unavailable")
        }
        let ready = expectation(description: "hardware frame encoded")
        let box = ViewerEncodedFrameBox()
        let encoder = try HostVideoEncoder(
            codec: codec,
            configuration: HostVideoEncoderConfiguration(
                width: 128, height: 128, framesPerSecond: 30, averageBitRate: 500_000),
            sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            onAccessUnit: { frame in
                box.store(frame)
                ready.fulfill()
            }, onState: { _ in }, onError: { error in XCTFail("encode failed: \(error)") })
        defer { encoder.invalidate() }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 128, 128, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            if let address = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                memset(
                    address, plane == 0 ? 16 : 128,
                    CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                        * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        try encoder.encode(
            pixelBuffer: pixelBuffer, presentationTime: CMTime(value: 1, timescale: 30),
            logicalRawFrameCopyCount: 0)
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(box.read())
    }
}
