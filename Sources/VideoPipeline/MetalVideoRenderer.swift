import Foundation
import CoreVideo
import IOSurface
import Metal
import MetalKit

public enum MetalRendererError: Error, CustomStringConvertible {
    case noDevice
    case commandQueue
    case textureCache(CVReturn)
    case shader(String)

    public var description: String {
        switch self {
        case .noDevice: return "no matching Metal device"
        case .commandQueue: return "failed to create Metal command queue"
        case .textureCache(let status): return "CVMetalTextureCacheCreate failed: \(status)"
        case .shader(let message): return "Metal shader setup failed: \(message)"
        }
    }
}

public enum GPUPreference: String, Sendable {
    case automatic
    case lowPower = "low-power"
    case highPerformance = "high-performance"
}

public final class MetalVideoRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let frameLock = NSLock()
    private var pendingFrames: [CVPixelBuffer] = []
    private static let maximumPendingFrames = 2
    private let metrics: PipelineMetrics

    public let deviceName: String

    public static func selectDevice(_ preference: GPUPreference) -> MTLDevice? {
        let devices = MTLCopyAllDevices()
        switch preference {
        case .lowPower:
            return devices.first(where: { $0.isLowPower })
        case .highPerformance:
            return devices.first(where: { !$0.isLowPower })
        case .automatic:
            return devices.first(where: { $0.isLowPower }) ?? MTLCreateSystemDefaultDevice()
        }
    }

    public init(view: MTKView, preference: GPUPreference, metrics: PipelineMetrics) throws {
        guard let device = Self.selectDevice(preference) else { throw MetalRendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalRendererError.commandQueue }
        self.device = device
        self.commandQueue = queue
        self.deviceName = device.name
        self.metrics = metrics

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalRendererError.shader(error.localizedDescription)
        }
        guard let vertex = library.makeFunction(name: "videoVertex"),
              let fragment = library.makeFunction(name: "nv12Fragment") else {
            throw MetalRendererError.shader("missing videoVertex or nv12Fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.shader(error.localizedDescription)
        }

        super.init()

        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard status == kCVReturnSuccess else { throw MetalRendererError.textureCache(status) }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        // Poll at the local 60 Hz cadence so a bursty relay stream can consume
        // every decoded frame without increasing the bounded two-frame queue.
        // The remote capture target remains 30 Hz; draws with no frame return
        // before acquiring a drawable below.
        view.preferredFramesPerSecond = 60
        view.delegate = self
    }

    public func enqueue(_ pixelBuffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            metrics.recordNonNV12(); return
        }
        if CVPixelBufferGetIOSurface(pixelBuffer) == nil { metrics.recordMissingIOSurface() }
        frameLock.lock()
        if pendingFrames.count >= Self.maximumPendingFrames {
            pendingFrames.removeFirst()
            metrics.recordDrop()
        }
        pendingFrames.append(pixelBuffer)
        metrics.recordRendererQueueDepth(pendingFrames.count)
        frameLock.unlock()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        frameLock.lock()
        let hasPendingFrame = !pendingFrames.isEmpty
        frameLock.unlock()
        guard hasPendingFrame,
              let cache = textureCache,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }

        frameLock.lock()
        let pixelBuffer = pendingFrames.isEmpty ? nil : pendingFrames.removeFirst()
        frameLock.unlock()

        guard let pixelBuffer else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        metrics.recordDrawableDimensions(width: drawable.texture.width, height: drawable.texture.height)
        var yTextureRef: CVMetalTexture?
        var uvTextureRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm,
            width, height, 0, &yTextureRef
        )
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm,
            width / 2, height / 2, 1, &uvTextureRef
        )
        guard yStatus == kCVReturnSuccess, uvStatus == kCVReturnSuccess,
              let yRef = yTextureRef, let uvRef = uvTextureRef,
              let yTexture = CVMetalTextureGetTexture(yRef),
              let uvTexture = CVMetalTextureGetTexture(uvRef),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            metrics.recordDrop(); return
        }

        let videoAspect = Float(width) / Float(height)
        let viewAspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        var scale: SIMD2<Float> = viewAspect > videoAspect
            ? SIMD2(videoAspect / viewAspect, 1)
            : SIMD2(1, viewAspect / videoAspect)

        encoder.setViewport(MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(drawable.texture.width),
            height: Double(drawable.texture.height),
            znear: 0,
            zfar: 1
        ))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)

        let submitted = DispatchTime.now().uptimeNanoseconds
        commandBuffer.addCompletedHandler { [metrics] _ in
            // Capturing these objects retains the IOSurface-backed frame until GPU completion.
            withExtendedLifetime((pixelBuffer, yRef, uvRef)) {}
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - submitted) / 1_000_000
            metrics.recordPresented(milliseconds: milliseconds)
        }
        commandBuffer.commit()
        CVMetalTextureCacheFlush(cache, 0)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut videoVertex(uint id [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0,  1.0), float2(1.0,  1.0)
        };
        const float2 texCoords[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };
        VertexOut out;
        out.position = float4(positions[id] * scale, 0.0, 1.0);
        out.texCoord = texCoords[id];
        return out;
    }

    fragment float4 nv12Fragment(
        VertexOut in [[stage_in]],
        texture2d<float> yTexture [[texture(0)]],
        texture2d<float> uvTexture [[texture(1)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float y = yTexture.sample(s, in.texCoord).r;
        float2 uv = uvTexture.sample(s, in.texCoord).rg;
        // Video-range BT.709: Y [16,235], Cb/Cr [16,240].
        y = 1.16438356 * (y - 16.0 / 255.0);
        float cb = uv.x - 0.5;
        float cr = uv.y - 0.5;
        float3 rgb = float3(
            y + 1.79274107 * cr,
            y - 0.21324861 * cb - 0.53290933 * cr,
            y + 2.11240179 * cb
        );
        return float4(saturate(rgb), 1.0);
    }
    """
}
