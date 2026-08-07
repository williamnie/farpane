import CoreMedia
import CoreVideo
import XCTest
@testable import VideoPipeline

private final class HostEncoderTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var accessUnits: [HostH264AccessUnit] = []
    private var runtimeState: HostEncoderRuntimeState?
    private var callbackError: HostH264EncoderError?

    func set(accessUnit: HostH264AccessUnit) {
        lock.lock(); defer { lock.unlock() }
        accessUnits.append(accessUnit)
    }

    func set(runtimeState: HostEncoderRuntimeState) {
        lock.lock(); defer { lock.unlock() }
        self.runtimeState = runtimeState
    }

    func set(error: HostH264EncoderError) {
        lock.lock(); defer { lock.unlock() }
        callbackError = error
    }

    func snapshot() -> ([HostH264AccessUnit], HostEncoderRuntimeState?, HostH264EncoderError?) {
        lock.lock(); defer { lock.unlock() }
        return (accessUnits, runtimeState, callbackError)
    }
}

final class HostH264EncoderTests: XCTestCase {
    func testHardwareH264EncodeReportsStateAfterFirstCallback() throws {
        guard HostH264Encoder.hardwareEncodingSupported else {
            throw XCTSkip("H.264 hardware encode is unavailable on this machine")
        }
        let accessUnitReady = expectation(description: "encoded access unit")
        accessUnitReady.expectedFulfillmentCount = 2
        let stateReady = expectation(description: "hardware state readback")
        let resultBox = HostEncoderTestResult()
        let encoder = try HostH264Encoder(
            configuration: HostH264EncoderConfiguration(
                width: 128,
                height: 128,
                framesPerSecond: 30,
                averageBitRate: 500_000
            ),
            sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            onAccessUnit: { value in
                resultBox.set(accessUnit: value)
                accessUnitReady.fulfill()
            },
            onState: { value in
                resultBox.set(runtimeState: value)
                stateReady.fulfill()
            },
            onError: { error in
                resultBox.set(error: error)
            }
        )
        let pixelBuffer = try makeNV12Buffer(width: 128, height: 128)
        try encoder.encode(
            pixelBuffer: pixelBuffer,
            presentationTime: CMTime(value: 1, timescale: 30),
            logicalRawFrameCopyCount: 0
        )
        encoder.requestKeyframe()
        try encoder.encode(
            pixelBuffer: pixelBuffer,
            presentationTime: CMTime(value: 2, timescale: 30),
            logicalRawFrameCopyCount: 0
        )
        wait(for: [accessUnitReady, stateReady], timeout: 5)
        encoder.invalidate()

        let (results, state, error) = resultBox.snapshot()
        XCTAssertNil(error)
        XCTAssertEqual(state?.hardwareAccelerated, true)
        XCTAssertEqual(state?.softwareFallback, false)
        XCTAssertFalse(state?.encoderID.isEmpty ?? true)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy(\.isKeyframe))
        XCTAssertTrue(results.allSatisfy(\.hasParameterSets))
        XCTAssertTrue(results.allSatisfy { $0.logicalRawFrameCopyCount == 0 })
        XCTAssertTrue(results.allSatisfy { !$0.data.isEmpty })
        let parsed = try results.map {
            try H264FramingAccessUnit(data: $0.data, framing: .avcc4)
        }
        XCTAssertTrue(parsed.allSatisfy(\.hasParameterSets))
        XCTAssertTrue(parsed.allSatisfy(\.isIDR))
    }

    private func makeNV12Buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "HostH264EncoderTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let address = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let fill: UInt8 = plane == 0 ? 16 : 128
            memset(address, Int32(fill), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        return buffer
    }
}
