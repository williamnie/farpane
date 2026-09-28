import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest

@testable import VideoPipeline

final class HostVideoEncoderCompatibilityTests: XCTestCase {
    func testInvalidConfigurationPreservesEachCodecErrorType() {
        let configuration = HostVideoEncoderConfiguration(
            width: 0, height: 128, framesPerSecond: 30, averageBitRate: 500_000)
        XCTAssertThrowsError(
            try HostH264Encoder(
                configuration: configuration,
                sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                onAccessUnit: { _ in }, onState: { _ in }, onError: { _ in })
        ) {
            guard case HostH264EncoderError.invalidConfiguration = $0 else {
                return XCTFail("\($0)")
            }
        }
        XCTAssertThrowsError(
            try HostHEVCEncoder(
                configuration: configuration,
                sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                onAccessUnit: { _ in }, onState: { _ in }, onError: { _ in })
        ) {
            guard case HostHEVCEncoderError.invalidConfiguration = $0 else {
                return XCTFail("\($0)")
            }
        }
    }

    func testInvalidatedSessionPreservesEachCodecErrorType() throws {
        guard HostH264Encoder.hardwareEncodingSupported, HostHEVCEncoder.hardwareEncodingSupported
        else { throw XCTSkip("Hardware encoders unavailable") }
        let configuration = HostVideoEncoderConfiguration(
            width: 128, height: 128, framesPerSecond: 30, averageBitRate: 500_000)
        let h264 = try HostH264Encoder(
            configuration: configuration,
            sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            onAccessUnit: { _ in }, onState: { _ in }, onError: { _ in })
        let hevc = try HostHEVCEncoder(
            configuration: configuration,
            sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            onAccessUnit: { _ in }, onState: { _ in }, onError: { _ in })
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 128, 128, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil,
                &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        h264.invalidate()
        hevc.invalidate()
        // 通过共享基类调用仍必须保留调用者可捕获的既有错误。
        for encoder: HostVideoEncoder in [h264, hevc] {
            XCTAssertThrowsError(
                try encoder.encode(
                    pixelBuffer: pixelBuffer, presentationTime: .zero, logicalRawFrameCopyCount: 0)
            ) {
                if encoder === h264 {
                    guard case HostH264EncoderError.encode(kVTInvalidSessionErr) = $0 else {
                        return XCTFail("\($0)")
                    }
                } else {
                    guard case HostHEVCEncoderError.encode(kVTInvalidSessionErr) = $0 else {
                        return XCTFail("\($0)")
                    }
                }
            }
        }
    }
}
