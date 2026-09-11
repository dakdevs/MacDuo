import AppKit
import CoreVideo
import MetalKit
import MetalPerformanceShaders

private struct RenderFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Only strong, immutable references cross onto Metal's completion queue. The image
// is never read or mutated there; releasing this lease returns it to the capture pool.
private final class CapturedFrameLease: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer?
    let metalTexture: CVMetalTexture?
    init(_ pixelBuffer: CVPixelBuffer?, _ metalTexture: CVMetalTexture?) {
        self.pixelBuffer = pixelBuffer
        self.metalTexture = metalTexture
    }
}

/// Uniform ABI: three float4 vectors, 16-byte aligned; offsets 0, 16, 32, stride 48.
private struct PlaneUniforms {
    var ray: SIMD4<Float>
    var style: SIMD4<Float> // visibility, closing amount, frost strength, perspective strength
    var texel: SIMD4<Float> // inverse source width/height, image-height scale, maximum blur mip
}

@MainActor
final class PlaneRenderer: NSObject, MTKViewDelegate {
    var degrees: Float = 90 { didSet { requestDraw() } }
    var calibration = ViewCalibration() { didSet { requestDraw() } }
    var onFailure: ((String) -> Void)?
    private(set) var hasFrame = false
    private(set) var isReadyForPresentation = false

    private weak var view: MTKView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var sourceTexture: MTLTexture?
    private var blurPyramid: MTLTexture?
    private var frameGeneration = 0
    private var preparationCommand: MTLCommandBuffer?
    private var sourcePixelBuffer: CVPixelBuffer?
    private var sourceMetalTexture: CVMetalTexture?

    init(view: MTKView) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw RenderFailure(message: "Metal is unavailable on this Mac.")
        }
        self.device = device
        self.commandQueue = queue
        self.view = view
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "planeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "planeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard result == kCVReturnSuccess else {
            throw RenderFailure(message: "Could not create the Metal image cache (\(result)).")
        }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.delegate = self
    }

    func setFrame(_ pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let textureCache else {
            throw RenderFailure(message: "The captured desktop is not a supported BGRA image.")
        }
        var metalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache,
            pixelBuffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer), 0, &metalTexture)
        guard status == kCVReturnSuccess, let metalTexture,
              let texture = CVMetalTextureGetTexture(metalTexture) else {
            throw RenderFailure(message: "Could not prepare the desktop image for Metal (\(status)).")
        }
        let (pyramid, preparation) = try prepareBlurPyramid(from: texture)
        frameGeneration += 1
        isReadyForPresentation = false
        let generation = frameGeneration
        let lease = CapturedFrameLease(pixelBuffer, metalTexture)
        preparation.addCompletedHandler { [weak self] result in
            withExtendedLifetime(lease) {}
            guard result.status == .error else { return }
            let message = result.error?.localizedDescription ?? "Could not prepare the frosted desktop."
            Task { @MainActor [weak self] in
                guard let self, self.frameGeneration == generation else { return }
                self.onFailure?(message)
            }
        }
        sourcePixelBuffer = pixelBuffer
        sourceMetalTexture = metalTexture
        sourceTexture = texture
        blurPyramid = pyramid
        hasFrame = true
        // All subsequent draws use this same queue, so the pyramid is ready first.
        preparationCommand = preparation
        preparation.commit()
        requestDraw()
    }

    func clearFrame() {
        frameGeneration += 1
        isReadyForPresentation = false
        preparationCommand = nil
        sourceTexture = nil
        blurPyramid = nil
        sourceMetalTexture = nil
        sourcePixelBuffer = nil
        hasFrame = false
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        requestDraw()
    }

    /// Render the initial screenshot while its window is still hidden. Returning
    /// means GPU rendering has completed and drawable presentation is queued;
    /// the caller can reveal the window without exposing an empty black surface.
    /// Missing drawables receive at most six attempts, with 16ms between attempts.
    func prepareForPresentation() async throws {
        guard hasFrame, let view else {
            throw RenderFailure(message: "There is no desktop snapshot to prepare.")
        }
        if isReadyForPresentation { return }
        let generation = frameGeneration
        let preparation = preparationCommand
        view.layoutSubtreeIfNeeded()
        for attempt in 0..<6 {
            try Task.checkCancellation()
            guard generation == frameGeneration, hasFrame else { throw CancellationError() }
            if let drawable = view.currentDrawable,
               let descriptor = view.currentRenderPassDescriptor {
                // This method obtains the drawable outside an MTKView draw callback,
                // so release its cached reference explicitly after command submission.
                let command: MTLCommandBuffer
                do { command = try encode(descriptor: descriptor) }
                catch { view.releaseDrawables(); throw error }
                command.present(drawable)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    command.addCompletedHandler { completed in
                        if completed.status == .completed {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: RenderFailure(message:
                                completed.error?.localizedDescription ?? "The first desktop frame could not be rendered."))
                        }
                    }
                    command.commit()
                    view.releaseDrawables()
                }
                try Task.checkCancellation()
                guard generation == frameGeneration, hasFrame else { throw CancellationError() }
                if let preparation, preparation.status != .completed {
                    throw RenderFailure(message: preparation.error?.localizedDescription
                        ?? "The desktop blur could not be prepared.")
                }
                // Presentation is already queued on the drawable; flush the layer
                // transaction before the caller changes window visibility/opacity.
                CATransaction.flush()
                preparationCommand = nil
                isReadyForPresentation = true
                return
            }
            view.releaseDrawables()
            if attempt < 5 { try await Task.sleep(nanoseconds: 16_666_667) }
        }
        throw RenderFailure(message: "The display did not provide a surface for the first desktop frame.")
    }

    func useTestPattern() throws {
        try setFrame(Self.makeTestPattern())
    }

    private static func makeTestPattern() throws -> CVPixelBuffer {
        let width = 1600
        let height = 1000
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw RenderFailure(message: "Could not create the calibration desktop.")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: address, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw RenderFailure(message: "Could not draw the calibration desktop.") }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
                  _ color: NSColor, weight: NSFont.Weight = .regular) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        }
        let ink = NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.21, alpha: 1)
        fill(CGRect(x: 0, y: 0, width: width, height: height),
             NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.93, alpha: 1))
        for x in stride(from: 0, through: width, by: 80) {
            fill(CGRect(x: x, y: 0, width: 1, height: height), NSColor.black.withAlphaComponent(0.065))
        }
        for y in stride(from: 0, through: height, by: 80) {
            fill(CGRect(x: 0, y: y, width: width, height: 1), NSColor.black.withAlphaComponent(0.065))
        }
        fill(CGRect(x: 0, y: 0, width: width, height: 48), NSColor.white.withAlphaComponent(0.72))
        text("MacDuo", 30, 12, 18, ink, weight: .semibold)
        text("Calibration desktop", 142, 12, 18, ink.withAlphaComponent(0.6))
        text("TOP · upright at 90°", 1340, 12, 18, ink)
        text("A desktop that holds its plane.", 100, 115, 51, ink, weight: .semibold)
        text("Close the lid slowly. The grid stays anchored to the hinge.", 103, 185, 25, ink.withAlphaComponent(0.65))
        let colors = [NSColor(calibratedRed: 0.22, green: 0.49, blue: 0.64, alpha: 1),
                      NSColor(calibratedRed: 0.80, green: 0.42, blue: 0.26, alpha: 1),
                      NSColor(calibratedRed: 0.43, green: 0.54, blue: 0.31, alpha: 1)]
        let labels = ["01  Perspective", "02  Desktop snapshot", "03  Gentle frost"]
        let details = ["Fixed at ninety degrees", "One image per closing gesture", "Dissolves as the lid closes"]
        for index in 0..<3 {
            let x = CGFloat(100 + index * 475)
            fill(CGRect(x: x, y: 285, width: 450, height: 450), NSColor.white.withAlphaComponent(0.85), radius: 22)
            fill(CGRect(x: x + 24, y: 309, width: 402, height: 260), colors[index], radius: 12)
            for offset in stride(from: 0, to: 5, by: 1) {
                fill(CGRect(x: x + 52 + CGFloat(offset * 69), y: 350,
                            width: 32, height: 165), NSColor.white.withAlphaComponent(0.12 + CGFloat(offset) * 0.11), radius: 10)
            }
            text(labels[index], x + 27, 601, 27, ink, weight: .semibold)
            text(details[index], x + 27, 648, 21, ink.withAlphaComponent(0.65))
        }
        fill(CGRect(x: 100, y: 800, width: 1400, height: 100), ink.withAlphaComponent(0.90), radius: 16)
        text("VIEWPOINT", 132, 827, 16, .white.withAlphaComponent(0.55), weight: .semibold)
        text("Adjust distance and eye height to match where you sit.", 295, 823, 26, .white)
        fill(CGRect(x: 0, y: height - 10, width: width, height: 10), ink)
        text("HINGE · this edge stays fixed", 621, 949, 23, ink, weight: .medium)
        return pixelBuffer
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        requestDraw()
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }
        do {
            let command = try encode(descriptor: descriptor)
            command.present(drawable)
            command.addCompletedHandler { [weak self] result in
                guard result.status == .error else { return }
                let message = result.error?.localizedDescription ?? "The GPU could not draw the desktop."
                Task { @MainActor [weak self] in self?.onFailure?(message) }
            }
            command.commit()
        } catch { onFailure?(error.localizedDescription) }
    }

    func renderPNG(to url: URL, width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw RenderFailure(message: "Invalid preview image dimensions.")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderFailure(message: "Could not allocate the preview image.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        let command = try encode(descriptor: pass)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw RenderFailure(message: command.error?.localizedDescription ?? "The GPU could not render the preview.")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw RenderFailure(message: "Could not encode the preview PNG.")
        }
        try png.write(to: url, options: .atomic)
    }

    /// Cache Gaussian diffusion once per snapshot. Starting at half resolution keeps
    /// the whole mip chain near one-third of the original image's pixel storage.
    /// Angle changes only sample this chain; they never re-run a blur kernel.
    private func prepareBlurPyramid(from source: MTLTexture) throws -> (MTLTexture, MTLCommandBuffer) {
        let width = max(1, source.width / 2)
        let height = max(1, source.height / 2)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: true)
        descriptor.mipmapLevelCount = min(7, descriptor.mipmapLevelCount)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        guard let pyramid = device.makeTexture(descriptor: descriptor),
              let command = commandQueue.makeCommandBuffer() else {
            throw RenderFailure(message: "Could not allocate the frosted desktop.")
        }
        pyramid.label = "MacDuo cached Gaussian pyramid"
        let downsample = MPSImageLanczosScale(device: device)
        downsample.edgeMode = .clamp
        let gaussian = MPSImageGaussianBlur(device: device, sigma: 2.2)
        gaussian.edgeMode = .clamp
        var previous = source
        for level in 0..<descriptor.mipmapLevelCount {
            let scratchDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: max(1, width >> level), height: max(1, height >> level), mipmapped: false)
            scratchDescriptor.storageMode = .private
            scratchDescriptor.usage = [.shaderRead, .shaderWrite]
            guard let scratch = device.makeTexture(descriptor: scratchDescriptor),
                  let destination = pyramid.makeTextureView(pixelFormat: .bgra8Unorm,
                    textureType: .type2D, levels: level..<(level + 1), slices: 0..<1) else {
                throw RenderFailure(message: "Could not prepare a Gaussian blur level.")
            }
            downsample.encode(commandBuffer: command, sourceTexture: previous, destinationTexture: scratch)
            gaussian.encode(commandBuffer: command, sourceTexture: scratch, destinationTexture: destination)
            previous = destination
        }
        return (pyramid, command)
    }

    private func requestDraw() {
        view?.needsDisplay = true
    }

    private func encode(descriptor: MTLRenderPassDescriptor) throws -> MTLCommandBuffer {
        guard let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw RenderFailure(message: "Could not begin a Metal render command.")
        }
        if let sourceTexture, let blurPyramid {
            let projection = PlaneProjection(degrees: degrees, calibration: calibration)
            var uniforms = PlaneUniforms(ray: projection.rayCoefficients,
                style: SIMD4(projection.visibility, projection.closingAmount,
                    calibration.frost.isFinite ? min(2, max(0, calibration.frost)) : 1,
                    projection.perspectiveStrength),
                texel: SIMD4(1 / Float(sourceTexture.width), 1 / Float(sourceTexture.height),
                    Float(sourceTexture.height) / 1000, Float(blurPyramid.mipmapLevelCount - 1)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentTexture(blurPyramid, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PlaneUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            // Capture-backed IOSurfaces must remain retained until the GPU is finished.
            let lease = CapturedFrameLease(sourcePixelBuffer, sourceMetalTexture)
            command.addCompletedHandler { _ in withExtendedLifetime(lease) {} }
        }
        encoder.endEncoding()
        return command
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 ray; float4 style; float4 texel; };
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex planeVertex(uint id [[vertex_id]]) {
        float2 corners[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        float2 p = corners[id];
        return { float4(p,0,1), float2(p.x * .5 + .5, .5 - p.y * .5) };
    }
    fragment float4 planeFragment(Vertex in [[stage_in]],
                                  texture2d<float> desktop [[texture(0)]],
                                  texture2d<float> frost [[texture(1)]],
                                  constant Uniforms &u [[buffer(0)]]) {
        if (u.style.x <= 0) return float4(0,0,0,1);
        float panelHeight = 1 - in.uv.y;
        float2 uv = in.uv;
        if (u.style.w > 0) {
            float denominator = u.ray.x - panelHeight * u.ray.z;
            if (denominator <= .00001) return float4(0,0,0,1);
            float2 projected = float2(.5 + (in.uv.x - .5) * u.ray.x / denominator,
                1 - panelHeight * (u.ray.x * u.ray.y - u.ray.w * u.ray.z) / denominator);
            uv = mix(in.uv, projected, u.style.w);
        }
        if (any(uv < 0) || any(uv > 1)) return float4(0,0,0,1);
        constexpr sampler sharpSample(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler frostSample(coord::normalized, address::clamp_to_edge,
                                      filter::linear, mip_filter::linear);
        float amount = u.style.y * u.style.y * u.style.z;
        // Measured in source pixels and scaled by image height, so Retina snapshots
        // receive the same apparent diffusion. The hinge remains much clearer.
        float radius = pow(u.style.y, 1.2) * u.style.z * 60 * u.texel.z
                     * (.06 + .94 * pow(panelHeight, .85));
        float blurLevel = clamp(log2(max(1.0, radius / 4.4)), 0.0, u.texel.w);
        float3 color = desktop.sample(sharpSample, uv).rgb;
        if (radius > 0) {
            float3 blurred = frost.sample(frostSample, uv, level(blurLevel)).rgb;
            color = mix(color, blurred, smoothstep(0.0, 4.4, radius));
        }
        // Subtle cool frost, with no blur, grain or tint at the upright angle.
        float luma = dot(color, float3(.2126,.7152,.0722));
        color = mix(color, float3(luma), min(.32, amount * .22));
        color = mix(color, float3(.78,.84,.87), min(.08, amount * .055));
        float edge = smoothstep(0.0, max(.000001, u.style.y * .004),
            min(min(uv.x,1-uv.x), min(uv.y,1-uv.y)));
        return float4(color * u.style.x * edge, 1);
    }
    """#
}
