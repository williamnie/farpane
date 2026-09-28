import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest

@testable import VideoPipeline

final class HostVideoEncoderCompatibilityTests: XCTestCase {
    func testInvalidConfigurationPreservesEachCodecErrorType() {
        XCTAssertThrowsError(
            try HostH264Encoder(
                configuration: .init(
                    width: 0, height: 128, framesPerSecond: 30, averageBitRate: 500_000),
                sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                onAccessUnit: { _ in }, onState: { _ in }, onError: { _ in })
        ) {
            guard case HostH264EncoderError.invalidConfiguration = $0 else {
                return XCTFail("\($0)")
            }
        }
        XCTAssertThrowsError(
            try HostHEVCEncoder(
                configuration: .init(
                    width: 0, height: 128, framesPerSecond: 30, averageBitRate: 500_000),
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
        let h264 = try HostH264Encoder(
            configuration: .init(
                width: 128, height: 128, framesPerSecond: 30, averageBitRate: 500_000),
            sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            onAccessUnit: { _ in }, onState: { _ in }, onError: { _ in })
        let hevc = try HostHEVCEncoder(
            configuration: .init(
                width: 128, height: 128, framesPerSecond: 30, averageBitRate: 500_000),
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

    func testPublicCodecTypesRemainDistinctForOverloadResolution() {
        let h264 = HostH264EncoderConfiguration(
            width: 128, height: 128, framesPerSecond: 30, averageBitRate: 500_000)
        let hevc = HostHEVCEncoderConfiguration(
            width: 128, height: 128, framesPerSecond: 30, averageBitRate: 500_000)
        XCTAssertEqual(codecName(h264), "h264")
        XCTAssertEqual(codecName(hevc), "hevc")
        XCTAssertEqual(
            codecName(
                HostH264AccessUnit(
                    data: Data(), presentationTimeUS: 0, isKeyframe: false, hasParameterSets: false,
                    logicalRawFrameCopyCount: 0)), "h264")
        XCTAssertEqual(
            codecName(
                HostHEVCAccessUnit(
                    data: Data(), presentationTimeUS: 0, isKeyframe: false, hasParameterSets: false,
                    logicalRawFrameCopyCount: 0)), "hevc")
    }

    // 若再次合并公开类型，这些原本合法的重载会直接导致编译失败。
    private func codecName(_ configuration: HostH264EncoderConfiguration) -> String { "h264" }
    private func codecName(_ configuration: HostHEVCEncoderConfiguration) -> String { "hevc" }
    private func codecName(_ unit: HostH264AccessUnit) -> String { "h264" }
    private func codecName(_ unit: HostHEVCAccessUnit) -> String { "hevc" }
}
