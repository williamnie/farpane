import AppKit
import MetalKit

private struct MotionUniforms {
    var phase: Float
    var aspect: Float
}

private final class MotionRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let start = CACurrentMediaTime()

    init?(view: MTKView) {
        guard
            let device = view.device,
            let commandQueue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
            let vertex = library.makeFunction(name: "motionVertex"),
            let fragment = library.makeFunction(name: "motionFragment")
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.commandQueue = commandQueue
        self.pipeline = pipeline
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        let width = max(1, Float(view.drawableSize.width))
        let height = max(1, Float(view.drawableSize.height))
        var uniforms = MotionUniforms(
            phase: Float(CACurrentMediaTime() - start),
            aspect: width / height
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<MotionUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct MotionUniforms {
        float phase;
        float aspect;
    };

    vertex VertexOut motionVertex(uint vertexID [[vertex_id]]) {
        const float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = positions[vertexID] * 0.5 + 0.5;
        return out;
    }

    fragment float4 motionFragment(VertexOut in [[stage_in]],
                                   constant MotionUniforms &uniforms [[buffer(0)]]) {
        float2 uv = in.uv;
        float verticalCenter = fract(uniforms.phase * 0.22) * 1.3 - 0.15;
        float horizontalCenter = fract(uniforms.phase * 0.16) * 1.3 - 0.15;
        float verticalBar = 1.0 - step(0.075, abs(uv.x - verticalCenter));
        float horizontalBar = 1.0 - step(0.06, abs(uv.y - horizontalCenter));
        float3 color = float3(0.012, 0.015, 0.022);
        color = mix(color, float3(0.94, 0.95, 1.0), verticalBar);
        color = mix(color, float3(0.05, 0.38, 0.92), horizontalBar * (1.0 - verticalBar));
        return float4(color, 1.0);
    }
    """
}

private final class MotionDelegate: NSObject, NSApplicationDelegate {
    private let duration: TimeInterval
    private var window: NSWindow?
    private var renderer: MotionRenderer?

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main, let device = MTLCreateSystemDefaultDevice() else {
            NSApp.terminate(nil)
            return
        }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .normal

        let view = MTKView(frame: screen.frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        guard let renderer = MotionRenderer(view: view) else {
            NSApp.terminate(nil)
            return
        }
        view.delegate = renderer

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.renderer = renderer

        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private let application = NSApplication.shared
private let duration = CommandLine.arguments.dropFirst().first.flatMap(TimeInterval.init) ?? 0
private let delegate = MotionDelegate(duration: duration)
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
