import Foundation
import Metal
import MetalKit
import AppKit

public struct Uniforms {
    public var imageSize: SIMD2<Float>
    public var cover: SIMD2<Float>
    public var aspect: Float
    public var turn: Float
    public var blurStrength: Float
    public var reflectionIntensity: Float
    public var sampleCount: Float
    public var motionBoost: Float
    
    public init(imageSize: SIMD2<Float> = .init(1, 1),
                cover: SIMD2<Float> = .init(1, 1),
                aspect: Float = 1.0,
                turn: Float = 0.0,
                blurStrength: Float = 1.0,
                reflectionIntensity: Float = 1.0,
                sampleCount: Float = 32.0,
                motionBoost: Float = 0.0) {
        self.imageSize = imageSize
        self.cover = cover
        self.aspect = aspect
        self.turn = turn
        self.blurStrength = blurStrength
        self.reflectionIntensity = reflectionIntensity
        self.sampleCount = sampleCount
        self.motionBoost = motionBoost
    }
}

public final class MetalFoldView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    
    private var currentTexture: MTLTexture?
    private var imageSize: SIMD2<Float> = .init(1920, 1080)
    
    public var currentTurn: Float = 0.0
    public var blurStrength: Float = 0.5
    public var reflectionIntensity: Float = 0.0

    // MARK: - Adaptive quality (close path only)

    /// 12 taps near open, 20 mid-fold, 32 on deep/fast close. Matches shader clamp.
    static func adaptiveSampleCount(turn: Float) -> Float {
        if turn < 0.20 { return 12.0 }
        if turn < 0.60 { return 20.0 }
        return 32.0
    }

    /// Velocity-aware boost in blur-radius units. Dead-zoned + clamped so HID
    /// jitter at rest adds nothing and fast slams stay silky, never mushy.
    static func velocityBlurBoost() -> Float {
        let v = abs(LidSensor.shared.smoothedVelocity) // deg/sec
        guard v > 30.0 else { return 0.0 }
        return Float(min((v - 30.0) * 0.02, 12.0))
    }

    /// Drop to 60fps when effectively parked; 120fps only while folding.
    /// Never called from draw() — mutating preferredFramesPerSecond mid-frame
    /// tears down the display link and causes pacing jitter. Call from update().
    func updateFrameRate(turn: Float) {
        let target = turn > 0.02 ? 120 : 60
        if preferredFramesPerSecond != target {
            preferredFramesPerSecond = target
        }
    }

    /// Resume the display link for active folding. Called on show.
    func resumeRendering() {
        if isPaused {
            isPaused = false
        }
    }

    /// Full suspend: 0fps floor. Releases triple-buffered Retina drawables
    /// (~90MB) so a hidden overlay costs WindowServer nothing. Called on hide.
    func suspendRendering() {
        isPaused = true
        releaseDrawables()
    }
    
    public init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac")
        }
        super.init(frame: frame, device: device)
        commonInit()
    }
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
        if self.device == nil {
            self.device = MTLCreateSystemDefaultDevice()
        }
        commonInit()
    }
    
    private func commonInit() {
        guard let dev = self.device else { return }
        
        self.commandQueue = dev.makeCommandQueue()
        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.003, green: 0.004, blue: 0.005, alpha: 1.0)
        // Drawable is render-target-only (never sampled) — lets CAMetalLayer
        // use the TBDR-optimized path. Parked state is fully suspended (0fps).
        self.framebufferOnly = true
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 120
        self.isPaused = true
        
        // Sampler
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        self.samplerState = dev.makeSamplerState(descriptor: samplerDesc)
        
        buildPipeline()
    }
    
    private func buildPipeline() {
        guard let dev = self.device else { return }
        
        var library: MTLLibrary?
        
        // Try to load compiled metallib first (check bundle for current class, then main)
        let bundle = Bundle(for: Self.self)
        if let libUrl = bundle.url(forResource: "default", withExtension: "metallib") ?? Bundle.main.url(forResource: "default", withExtension: "metallib") {
            library = try? dev.makeLibrary(URL: libUrl)
        }
        
        if library == nil {
            library = dev.makeDefaultLibrary()
        }
        
        // If still nil, compile from source file directly (bundle-relative only, no hardcoded dev paths)
        if library == nil {
            var possiblePaths: [String] = [
                Bundle.main.bundlePath + "/Contents/Resources/FoldShaders.metal",
                Bundle.main.bundlePath + "/FoldShaders.metal"
            ]
            if let classBundlePath = Bundle(for: Self.self).path(forResource: "FoldShaders", ofType: "metal") {
                possiblePaths.insert(classBundlePath, at: 0)
            }
            for p in possiblePaths {
                if let source = try? String(contentsOfFile: p, encoding: .utf8) {
                    library = try? dev.makeLibrary(source: source, options: nil)
                    if library != nil { break }
                }
            }
        }
        
        guard let lib = library else {
            print("[MetalFoldView] Failed to find or compile Metal library.")
            return
        }
        
        let vertexFunc = lib.makeFunction(name: "foldVertex")
        let fragmentFunc = lib.makeFunction(name: "foldFragment")
        
        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.vertexFunction = vertexFunc
        pipeDesc.fragmentFunction = fragmentFunc
        pipeDesc.colorAttachments[0].pixelFormat = self.colorPixelFormat
        
        self.pipelineState = try? dev.makeRenderPipelineState(descriptor: pipeDesc)
    }
    
    // Monotonic generation: drops stale uploads when captures overlap.
    private var textureGeneration: UInt64 = 0

    /// Upload a capture to the GPU. Heavy work (CG decode + draw + mip blit)
    /// runs on a background queue; only the finished texture assignment hops
    /// to main. draw() holds the texture for the frame, so swapping is safe.
    public func updateImage(_ cgImage: CGImage) {
        guard let dev = self.device, let cq = self.commandQueue else { return }

        textureGeneration &+= 1
        let generation = textureGeneration
        let width = cgImage.width
        let height = cgImage.height

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let texture = Self.makeFoldTexture(device: dev, cgImage: cgImage, width: width, height: height),
                  let cb = cq.makeCommandBuffer(),
                  let blit = cb.makeBlitCommandEncoder() else { return }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            // Publish on completion: assignment lands on main only for the
            // newest generation; older overlapping uploads are discarded.
            cb.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.textureGeneration == generation else { return }
                    self.imageSize = SIMD2<Float>(Float(width), Float(height))
                    self.currentTexture = texture
                }
            }
            cb.commit()
        }
    }

    /// Decode + stage a fold texture. Background-safe: touches no view state.
    /// Source texture is shader-read-only (never a render target), letting the
    /// driver keep it out of tile memory on Apple Silicon TBDR GPUs.
    private static func makeFoldTexture(device: MTLDevice, cgImage: CGImage, width: Int, height: Int) -> MTLTexture? {
        let levels = max(1, Int(floor(log2(Double(max(width, height))))))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: true
        )
        desc.mipmapLevelCount = levels
        desc.usage = [.shaderRead]
        desc.storageMode = .private

        // Stage through a shared CPU-visible texture, then GPU-side blit into
        // private storage — no synchronous replace() into renderable memory.
        let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        stageDesc.usage = [.shaderRead]
        stageDesc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc),
              let staging = device.makeTexture(descriptor: stageDesc) else { return nil }

        // Render CGImage into level 0
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        staging.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        guard let cq = device.makeCommandQueue(),
              let cb = cq.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return texture
    }
    
    // MARK: - MTKViewDelegate
    
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let pipeline = self.pipelineState,
              let texture = self.currentTexture,
              let cq = self.commandQueue,
              let cb = cq.makeCommandBuffer(),
              let encoder = cb.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }
        
        let viewSize = view.drawableSize
        let aspect = Float(viewSize.width / max(1.0, viewSize.height))
        let imgAspect = imageSize.x / max(1.0, imageSize.y)
        
        let cover = SIMD2<Float>(
            min(1.0, aspect / imgAspect),
            min(1.0, imgAspect / aspect)
        )
        
        var uniforms = Uniforms(
            imageSize: imageSize,
            cover: cover,
            aspect: aspect,
            turn: currentTurn,
            blurStrength: blurStrength,
            reflectionIntensity: reflectionIntensity,
            sampleCount: Self.adaptiveSampleCount(turn: currentTurn),
            motionBoost: Self.velocityBlurBoost()
        )
        
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        
        cb.present(drawable)
        cb.commit()
    }
}
