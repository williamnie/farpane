import Foundation
import CoreVideo

public final class FixturePlayer: @unchecked Sendable {
    private let stream: HEVCAnnexBStream
    private let fps: Double
    private let metrics: PipelineMetrics
    private let decoder: VideoToolboxDecoder
    private let queue = DispatchQueue(label: "io.rustdesknative.fixture-player", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var nextIndex = 0
    private var sequence: Int64 = 0

    public init(
        fixtureURL: URL,
        fps: Double,
        metrics: PipelineMetrics,
        output: @escaping VideoToolboxDecoder.FrameHandler
    ) throws {
        stream = try HEVCAnnexBStream(data: Data(contentsOf: fixtureURL))
        self.fps = fps
        self.metrics = metrics
        decoder = try VideoToolboxDecoder(parameterSets: stream.parameterSets, metrics: metrics, output: output)
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.submitNextFrame() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        decoder.finishDelayedFrames()
    }

    private func submitNextFrame() {
        guard !stream.accessUnits.isEmpty else { return }
        guard decoder.pendingFrames < 2 else { metrics.recordDrop(); return }
        if nextIndex == 0, !stream.accessUnits[0].isKeyframe {
            metrics.recordDecodeError(); return
        }
        let unit = stream.accessUnits[nextIndex]
        do {
            try decoder.decode(unit, sequence: sequence, fps: fps)
        } catch {
            metrics.recordDecodeError()
            fputs("decode submit error: \(error)\n", stderr)
        }
        sequence += 1
        nextIndex = (nextIndex + 1) % stream.accessUnits.count
    }
}

