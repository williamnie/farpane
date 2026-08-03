import Foundation
import Darwin

public final class PipelineMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private let startedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private let initialCPUSeconds: Double
    private let initialResidentBytes: UInt64
    private var decodedFrames = 0
    private var presentedFrames = 0
    private var firstPresentationUptimeNanoseconds: UInt64?
    private var lastPresentationUptimeNanoseconds: UInt64?
    private var maxPresentationGapMilliseconds = 0.0
    private var firstUnpresentedEncodedUptimeNanoseconds: UInt64?
    private var lastEncodedUptimeNanoseconds: UInt64?
    private var maxPresentationStalenessWhileReceivingMilliseconds = 0.0
    private var submittedFrames = 0
    private var droppedFrames = 0
    private var referenceFrameDrops = 0
    private var backpressureWaits = 0
    private var maxBackpressureWaitMilliseconds = 0.0
    private var decodeErrors = 0
    private var firstDecodeErrorStatus: Int32?
    private var lastDecodeErrorStatus: Int32?
    private var decoderResets = 0
    private var keyframeRequests = 0
    private var nonNV12Frames = 0
    private var missingIOSurfaceFrames = 0
    private var maxQueueDepth = 0
    private var maxRendererQueueDepth = 0
    private var decodeMilliseconds: [Double] = []
    private var renderMilliseconds: [Double] = []
    private var peakResidentBytes: UInt64 = 0
    private var warmupResidentBytes: UInt64?
    private var observedWidth = 0
    private var observedHeight = 0
    private var drawableWidth = 0
    private var drawableHeight = 0
    private var hardwareDecodeActive = false
    private var remoteEncodedWidth = 0
    private var remoteEncodedHeight = 0
    private var encodedPackets = 0
    private var encodedFrames = 0
    private var encodedBytes: UInt64 = 0
    private var firstEncodedUptimeNanoseconds: UInt64?
    private var lastEncodedTimestampUS: UInt64?
    private var annexBPackets = 0
    private var avccPackets = 0
    private var mixedPackets = 0
    private var unknownFormatPackets = 0
    private var h265Packets = 0
    private var nonH265Packets = 0
    private var keyframes = 0
    private var packetsWithVPS = 0
    private var packetsWithSPS = 0
    private var packetsWithPPS = 0
    private var packetSequenceGaps: UInt64 = 0
    private var lastPacketSequence: UInt64?
    private var stateTransitions: [String] = []
    private var coreRemoteFPS = 0.0
    private var coreNetworkDelayMS = -1
    private var coreTargetBitrate: UInt64 = 0
    private var inputPointerMoves = 0
    private var inputButtonDowns = 0
    private var inputButtonUps = 0
    private var inputScrollEvents = 0
    private var inputKeyDowns = 0
    private var inputKeyUps = 0
    private var inputRejectedEvents = 0
    private var fullscreenToggles = 0
    private var hudToggles = 0
    private var exclusiveKeyboardActivations = 0
    private var exclusiveKeyboardFailures = 0
    private var functionalChecks: [String: Bool] = [:]

    public let inputWidth: Int
    public let inputHeight: Int
    public let inputFPS: Double
    public let codec = "hevc"
    public let selectedGPU: String
    public let source: String

    public init(
        inputWidth: Int,
        inputHeight: Int,
        inputFPS: Double,
        selectedGPU: String,
        source: String = "fixture"
    ) {
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.inputFPS = inputFPS
        self.selectedGPU = selectedGPU
        self.source = source
        initialCPUSeconds = Self.currentCPUSeconds()
        initialResidentBytes = Self.currentResidentBytes()
        peakResidentBytes = initialResidentBytes
        sampleMemory()
    }

    public func recordSubmitted(queueDepth: Int) { locked { submittedFrames += 1; maxQueueDepth = max(maxQueueDepth, queueDepth) } }
    public func recordDecoded(milliseconds: Double) { locked { decodedFrames += 1; decodeMilliseconds.append(milliseconds) } }
    public func recordPresented(milliseconds: Double) {
        let now = DispatchTime.now().uptimeNanoseconds
        locked {
            if firstPresentationUptimeNanoseconds == nil {
                firstPresentationUptimeNanoseconds = now
            }
            if let previous = lastPresentationUptimeNanoseconds, now >= previous {
                maxPresentationGapMilliseconds = max(
                    maxPresentationGapMilliseconds,
                    Double(now - previous) / 1_000_000
                )
            }
            lastPresentationUptimeNanoseconds = now
            firstUnpresentedEncodedUptimeNanoseconds = nil
            presentedFrames += 1
            renderMilliseconds.append(milliseconds)
        }
    }
    public func recordDrop() { locked { droppedFrames += 1 } }
    public func recordReferenceFrameDrop() {
        locked {
            referenceFrameDrops += 1
            droppedFrames += 1
        }
    }
    public func recordBackpressureWait(milliseconds: Double) {
        locked {
            backpressureWaits += 1
            maxBackpressureWaitMilliseconds = max(maxBackpressureWaitMilliseconds, milliseconds)
        }
    }
    public func recordDecodeError(status: Int32? = nil) {
        locked {
            decodeErrors += 1
            if let status {
                if firstDecodeErrorStatus == nil { firstDecodeErrorStatus = status }
                lastDecodeErrorStatus = status
            }
        }
    }
    public func recordDecoderReset(status: Int32?) {
        locked {
            decoderResets += 1
            if let status {
                if firstDecodeErrorStatus == nil { firstDecodeErrorStatus = status }
                lastDecodeErrorStatus = status
            }
        }
    }
    public func recordKeyframeRequest() { locked { keyframeRequests += 1 } }
    public func recordDecodedDimensions(width: Int, height: Int) {
        locked {
            if observedWidth == 0 { observedWidth = width; observedHeight = height }
        }
    }
    public func recordDrawableDimensions(width: Int, height: Int) {
        locked { drawableWidth = width; drawableHeight = height }
    }
    public func recordHardwareDecode(active: Bool) { locked { hardwareDecodeActive = active } }
    public func recordNonNV12() { locked { nonNV12Frames += 1 } }
    public func recordMissingIOSurface() { locked { missingIOSurfaceFrames += 1 } }
    public func recordRendererQueueDepth(_ depth: Int) {
        locked { maxRendererQueueDepth = max(maxRendererQueueDepth, depth) }
    }
    public func recordEncodedPacket(
        codec: String,
        format: String,
        byteCount: Int,
        sequence: UInt64,
        timestampUS: UInt64,
        isKeyframe: Bool,
        containsVPS: Bool,
        containsSPS: Bool,
        containsPPS: Bool,
        width: Int,
        height: Int
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        locked {
            if firstUnpresentedEncodedUptimeNanoseconds == nil {
                firstUnpresentedEncodedUptimeNanoseconds = now
            }
            let baseline = firstUnpresentedEncodedUptimeNanoseconds ?? now
            if now >= baseline {
                maxPresentationStalenessWhileReceivingMilliseconds = max(
                    maxPresentationStalenessWhileReceivingMilliseconds,
                    Double(now - baseline) / 1_000_000
                )
            }
            encodedPackets += 1
            if timestampUS == 0 || lastEncodedTimestampUS != timestampUS {
                if firstEncodedUptimeNanoseconds == nil {
                    firstEncodedUptimeNanoseconds = now
                }
                lastEncodedUptimeNanoseconds = now
                encodedFrames += 1
            }
            lastEncodedTimestampUS = timestampUS
            encodedBytes += UInt64(max(0, byteCount))
            if codec == "h265" { h265Packets += 1 } else { nonH265Packets += 1 }
            switch format {
            case "annex-b": annexBPackets += 1
            case "avcc": avccPackets += 1
            case "mixed": mixedPackets += 1
            default: unknownFormatPackets += 1
            }
            if isKeyframe { keyframes += 1 }
            if containsVPS { packetsWithVPS += 1 }
            if containsSPS { packetsWithSPS += 1 }
            if containsPPS { packetsWithPPS += 1 }
            if width > 0, height > 0 {
                remoteEncodedWidth = width
                remoteEncodedHeight = height
            }
            if let previous = lastPacketSequence, sequence > previous + 1 {
                packetSequenceGaps += sequence - previous - 1
            }
            lastPacketSequence = sequence
        }
    }
    public func recordCoreState(_ value: String) {
        locked {
            if stateTransitions.last != value { stateTransitions.append(value) }
        }
    }
    public func recordCoreMetrics(remoteFPS: Double, networkDelayMS: Int, targetBitrate: UInt64) {
        locked {
            if remoteFPS > 0 { coreRemoteFPS = remoteFPS }
            if networkDelayMS >= 0 { coreNetworkDelayMS = networkDelayMS }
            if targetBitrate > 0 { coreTargetBitrate = targetBitrate }
        }
    }

    public func recordInput(category: String, accepted: Bool) {
        locked {
            if !accepted { inputRejectedEvents += 1; return }
            switch category {
            case "pointer-move": inputPointerMoves += 1
            case "button-down": inputButtonDowns += 1
            case "button-up": inputButtonUps += 1
            case "scroll": inputScrollEvents += 1
            case "key-down": inputKeyDowns += 1
            case "key-up": inputKeyUps += 1
            default: break
            }
        }
    }
    public func recordFullscreenToggle() { locked { fullscreenToggles += 1 } }
    public func recordHUDToggle() { locked { hudToggles += 1 } }
    public func recordExclusiveKeyboardActivation() { locked { exclusiveKeyboardActivations += 1 } }
    public func recordExclusiveKeyboardFailure() { locked { exclusiveKeyboardFailures += 1 } }
    public func recordFunctionalCheck(_ name: String, passed: Bool) {
        locked { functionalChecks[name] = passed }
    }
    public func functionalChecksSnapshot() -> [String: Bool] { locked { functionalChecks } }

    public func hudSnapshot() -> PipelineHUDSnapshot {
        let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
        let cpuSeconds = Self.currentCPUSeconds() - initialCPUSeconds
        let residentMB = Double(Self.currentResidentBytes()) / 1_048_576
        return locked {
            PipelineHUDSnapshot(
                encodedFPS: Self.activeFrameRate(
                    count: encodedFrames,
                    first: firstEncodedUptimeNanoseconds,
                    last: lastEncodedUptimeNanoseconds,
                    fallback: Double(encodedFrames) / elapsed
                ),
                presentedFPS: Self.activeFrameRate(
                    count: presentedFrames,
                    first: firstPresentationUptimeNanoseconds,
                    last: lastPresentationUptimeNanoseconds,
                    fallback: Double(presentedFrames) / elapsed
                ),
                remoteWidth: remoteEncodedWidth,
                remoteHeight: remoteEncodedHeight,
                drawableWidth: drawableWidth,
                drawableHeight: drawableHeight,
                decodeMS: Self.average(decodeMilliseconds),
                renderMS: Self.average(renderMilliseconds),
                droppedFrames: droppedFrames,
                decoderQueueDepth: maxQueueDepth,
                rendererQueueDepth: maxRendererQueueDepth,
                networkDelayMS: coreNetworkDelayMS,
                cpuPercent: cpuSeconds / elapsed * 100,
                residentMB: residentMB,
                inputEvents: inputPointerMoves + inputButtonDowns + inputButtonUps + inputScrollEvents + inputKeyDowns + inputKeyUps,
                inputRejectedEvents: inputRejectedEvents
            )
        }
    }

    public func sampleMemory() {
        let resident = Self.currentResidentBytes()
        locked {
            peakResidentBytes = max(peakResidentBytes, resident)
            if warmupResidentBytes == nil, Date().timeIntervalSince(startedAt) >= 5 {
                warmupResidentBytes = resident
            }
        }
    }

    public func snapshot(durationOverride: Double? = nil) -> BenchmarkReport {
        sampleMemory()
        let elapsed = durationOverride ?? Date().timeIntervalSince(startedAt)
        let cpuSeconds = Self.currentCPUSeconds() - initialCPUSeconds
        let finalResidentBytes = Self.currentResidentBytes()
        let snapshotUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        return locked {
            let endToEndPresentedFPS = elapsed > 0 ? Double(presentedFrames) / elapsed : 0
            let activePresentedFPS = Self.activeFrameRate(
                count: presentedFrames,
                first: firstPresentationUptimeNanoseconds,
                last: lastPresentationUptimeNanoseconds,
                fallback: endToEndPresentedFPS
            )
            let endToEndEncodedFPS = elapsed > 0 ? Double(encodedFrames) / elapsed : 0
            let activeEncodedFPS = Self.activeFrameRate(
                count: encodedFrames,
                first: firstEncodedUptimeNanoseconds,
                last: lastEncodedUptimeNanoseconds,
                fallback: endToEndEncodedFPS
            )
            return BenchmarkReport(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                source: source,
                durationSeconds: elapsed,
                codec: codec,
                inputWidth: inputWidth,
                inputHeight: inputHeight,
                inputFPS: inputFPS,
                observedWidth: observedWidth,
                observedHeight: observedHeight,
                drawableWidth: drawableWidth,
                drawableHeight: drawableHeight,
                selectedGPU: selectedGPU,
                processCPUPercent: elapsed > 0 ? cpuSeconds / elapsed * 100 : 0,
                initialResidentMB: Double(initialResidentBytes) / 1_048_576,
                finalResidentMB: Double(finalResidentBytes) / 1_048_576,
                peakResidentMB: Double(peakResidentBytes) / 1_048_576,
                memoryGrowthMB: Double(Int64(finalResidentBytes) - Int64(initialResidentBytes)) / 1_048_576,
                peakMemoryGrowthMB: Double(Int64(peakResidentBytes) - Int64(initialResidentBytes)) / 1_048_576,
                steadyStateMemoryGrowthMB: warmupResidentBytes.map {
                    Double(Int64(finalResidentBytes) - Int64($0)) / 1_048_576
                } ?? 0,
                submittedFrames: submittedFrames,
                decodedFrames: decodedFrames,
                presentedFrames: presentedFrames,
                droppedFrames: droppedFrames,
                referenceFrameDrops: referenceFrameDrops,
                backpressureWaits: backpressureWaits,
                maxBackpressureWaitMS: maxBackpressureWaitMilliseconds,
                decodeErrors: decodeErrors,
                firstDecodeErrorStatus: firstDecodeErrorStatus,
                lastDecodeErrorStatus: lastDecodeErrorStatus,
                decoderResets: decoderResets,
                keyframeRequests: keyframeRequests,
                measuredFPS: activePresentedFPS,
                endToEndPresentedFPS: endToEndPresentedFPS,
                maxPresentationGapMS: maxPresentationGapMilliseconds,
                finalPresentationStalenessMS: Double(
                    snapshotUptimeNanoseconds - (lastPresentationUptimeNanoseconds ?? startedUptimeNanoseconds)
                ) / 1_000_000,
                maxPresentationStalenessWhileReceivingMS: maxPresentationStalenessWhileReceivingMilliseconds,
                finalEncodedToPresentationStalenessMS: {
                    guard let encoded = lastEncodedUptimeNanoseconds,
                          let baseline = firstUnpresentedEncodedUptimeNanoseconds,
                          encoded > baseline else { return 0 }
                    return Double(encoded - baseline) / 1_000_000
                }(),
                maxQueueDepth: maxQueueDepth,
                maxRendererQueueDepth: maxRendererQueueDepth,
                averageDecodeMS: Self.average(decodeMilliseconds),
                p95DecodeMS: Self.percentile95(decodeMilliseconds),
                averageRenderMS: Self.average(renderMilliseconds),
                p95RenderMS: Self.percentile95(renderMilliseconds),
                nonNV12Frames: nonNV12Frames,
                missingIOSurfaceFrames: missingIOSurfaceFrames,
                cpuRGBAFallback: false,
                hardwareDecodeRequired: true,
                hardwareDecodeActive: hardwareDecodeActive,
                remoteEncodedWidth: remoteEncodedWidth,
                remoteEncodedHeight: remoteEncodedHeight,
                encodedPackets: encodedPackets,
                encodedFrames: encodedFrames,
                measuredEncodedFPS: activeEncodedFPS,
                endToEndEncodedFPS: endToEndEncodedFPS,
                encodedBytes: encodedBytes,
                annexBPackets: annexBPackets,
                avccPackets: avccPackets,
                mixedPackets: mixedPackets,
                unknownFormatPackets: unknownFormatPackets,
                h265Packets: h265Packets,
                nonH265Packets: nonH265Packets,
                keyframes: keyframes,
                packetsWithVPS: packetsWithVPS,
                packetsWithSPS: packetsWithSPS,
                packetsWithPPS: packetsWithPPS,
                packetSequenceGaps: packetSequenceGaps,
                coreStateTransitions: stateTransitions,
                coreRemoteFPS: coreRemoteFPS,
                coreNetworkDelayMS: coreNetworkDelayMS,
                coreTargetBitrate: coreTargetBitrate,
                inputPointerMoves: inputPointerMoves,
                inputButtonDowns: inputButtonDowns,
                inputButtonUps: inputButtonUps,
                inputScrollEvents: inputScrollEvents,
                inputKeyDowns: inputKeyDowns,
                inputKeyUps: inputKeyUps,
                inputRejectedEvents: inputRejectedEvents,
                fullscreenToggles: fullscreenToggles,
                hudToggles: hudToggles,
                exclusiveKeyboardActivations: exclusiveKeyboardActivations,
                exclusiveKeyboardFailures: exclusiveKeyboardFailures,
                functionalChecks: functionalChecks
            )
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
    }

    private static func activeFrameRate(
        count: Int,
        first: UInt64?,
        last: UInt64?,
        fallback: Double
    ) -> Double {
        guard count > 1, let first, let last, last > first else { return fallback }
        let seconds = Double(last - first) / 1_000_000_000
        return Double(count - 1) / seconds
    }

    private static func currentCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private static func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

public struct PipelineHUDSnapshot: Sendable {
    public let encodedFPS: Double
    public let presentedFPS: Double
    public let remoteWidth: Int
    public let remoteHeight: Int
    public let drawableWidth: Int
    public let drawableHeight: Int
    public let decodeMS: Double
    public let renderMS: Double
    public let droppedFrames: Int
    public let decoderQueueDepth: Int
    public let rendererQueueDepth: Int
    public let networkDelayMS: Int
    public let cpuPercent: Double
    public let residentMB: Double
    public let inputEvents: Int
    public let inputRejectedEvents: Int
}

public struct BenchmarkReport: Codable, Sendable {
    public let timestamp: String
    public let source: String
    public let durationSeconds: Double
    public let codec: String
    public let inputWidth: Int
    public let inputHeight: Int
    public let inputFPS: Double
    public let observedWidth: Int
    public let observedHeight: Int
    public let drawableWidth: Int
    public let drawableHeight: Int
    public let selectedGPU: String
    public let processCPUPercent: Double
    public let initialResidentMB: Double
    public let finalResidentMB: Double
    public let peakResidentMB: Double
    public let memoryGrowthMB: Double
    public let peakMemoryGrowthMB: Double
    public let steadyStateMemoryGrowthMB: Double
    public let submittedFrames: Int
    public let decodedFrames: Int
    public let presentedFrames: Int
    public let droppedFrames: Int
    public let referenceFrameDrops: Int
    public let backpressureWaits: Int
    public let maxBackpressureWaitMS: Double
    public let decodeErrors: Int
    public let firstDecodeErrorStatus: Int32?
    public let lastDecodeErrorStatus: Int32?
    public let decoderResets: Int
    public let keyframeRequests: Int
    public let measuredFPS: Double
    public let endToEndPresentedFPS: Double
    public let maxPresentationGapMS: Double
    public let finalPresentationStalenessMS: Double
    public let maxPresentationStalenessWhileReceivingMS: Double
    public let finalEncodedToPresentationStalenessMS: Double
    public let maxQueueDepth: Int
    public let maxRendererQueueDepth: Int
    public let averageDecodeMS: Double
    public let p95DecodeMS: Double
    public let averageRenderMS: Double
    public let p95RenderMS: Double
    public let nonNV12Frames: Int
    public let missingIOSurfaceFrames: Int
    public let cpuRGBAFallback: Bool
    public let hardwareDecodeRequired: Bool
    public let hardwareDecodeActive: Bool
    public let remoteEncodedWidth: Int
    public let remoteEncodedHeight: Int
    public let encodedPackets: Int
    public let encodedFrames: Int
    public let measuredEncodedFPS: Double
    public let endToEndEncodedFPS: Double
    public let encodedBytes: UInt64
    public let annexBPackets: Int
    public let avccPackets: Int
    public let mixedPackets: Int
    public let unknownFormatPackets: Int
    public let h265Packets: Int
    public let nonH265Packets: Int
    public let keyframes: Int
    public let packetsWithVPS: Int
    public let packetsWithSPS: Int
    public let packetsWithPPS: Int
    public let packetSequenceGaps: UInt64
    public let coreStateTransitions: [String]
    public let coreRemoteFPS: Double
    public let coreNetworkDelayMS: Int
    public let coreTargetBitrate: UInt64
    public let inputPointerMoves: Int
    public let inputButtonDowns: Int
    public let inputButtonUps: Int
    public let inputScrollEvents: Int
    public let inputKeyDowns: Int
    public let inputKeyUps: Int
    public let inputRejectedEvents: Int
    public let fullscreenToggles: Int
    public let hudToggles: Int
    public let exclusiveKeyboardActivations: Int
    public let exclusiveKeyboardFailures: Int
    public let functionalChecks: [String: Bool]
}
