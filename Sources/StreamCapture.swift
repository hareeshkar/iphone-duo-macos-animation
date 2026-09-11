import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
// Pre-concurrency framework: SCStream isn't Sendable-annotated. All stream
// handles are confined to outputQueue or published under lock — audited.
@preconcurrency import ScreenCaptureKit

/// Warm-stream zero-copy capture. Holds a persistent SCStream delivering
/// IOSurface-backed frames; takeLatestTexture maps the newest frame straight
/// into a Metal texture — no CG decode, no CGContext draw, no staging copy.
/// ~2 full-frame CPU passes and 50-200ms of show latency disappear versus the
/// one-shot path. Any failure → caller falls back to SCScreenshotManager.
///
/// Lifecycle: primed on lid pre-arm (stream is warm before the fold), kept
/// across shows, stopped 5s after hide. Idle cost when parked: zero.
///
/// Synchronization: manually synchronized — all mutable state under `lock`
/// except lifecycle flags confined to `outputQueue`. Declared Sendable on
/// that basis; NSLock is never touched from an async context.
public final class StreamCapture: NSObject, @unchecked Sendable {
    public static let shared = StreamCapture()

    /// Kill switch: false forces the one-shot path everywhere. Flip without
    /// touching call sites if the stream ever misbehaves on a given machine.
    public static var fastPathEnabled = true

    private let lock = NSLock()
    private var stream: SCStream?
    private var running = false
    private var starting = false
    private var latestPixelBuffer: CVPixelBuffer?
    private var textureCache: CVMetalTextureCache?
    private var cacheDevice: MTLDevice?
    private var stopWorkItem: DispatchWorkItem?
    private let outputQueue = DispatchQueue(label: "com.mactilt.stream-output", qos: .utility)

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle (all state transitions on outputQueue)

    /// Start warming the stream. Cheap when already warm; no-op when disabled.
    public func prime() {
        guard Self.fastPathEnabled else { return }
        outputQueue.async { [weak self] in
            self?.startIfNeeded()
        }
    }

    /// Overlay is visible (or about to be): cancel any pending idle stop.
    public func noteVisible() {
        guard Self.fastPathEnabled else { return }
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.stopWorkItem?.cancel()
            self.stopWorkItem = nil
            self.startIfNeeded()
        }
    }

    /// Overlay hidden: stop the stream after 5s idle. WindowServer stops
    /// compositing for us the moment nobody consumes.
    public func noteHidden() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.stopWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.stopStream()
            }
            self.stopWorkItem = item
            self.outputQueue.asyncAfter(deadline: .now() + 5.0, execute: item)
        }
    }

    /// Display set changed: the cached filter's geometry is stale. Tear down
    /// now; the next prime/visible restarts against the new configuration.
    public func restart() {
        guard Self.fastPathEnabled else { return }
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.stopWorkItem?.cancel()
            self.stopWorkItem = nil
            self.stopStream()
        }
    }

    private func startIfNeeded() {
        guard !running && !starting else { return }
        guard ScreenCapture.shared.hasPermission() else { return }
        starting = true
        // Detached: startStream awaits with no locks held; completion hops
        // back to outputQueue where all flag mutation is confined.
        let queue = outputQueue
        Task.detached(priority: .utility) { [weak self] in
            let stream = await self?.startStream()
            queue.async { [weak self] in
                self?.starting = false
                if let stream {
                    self?.lock.lock()
                    self?.stream = stream
                    self?.running = true
                    self?.lock.unlock()
                } else {
                    self?.running = false
                }
            }
        }
    }

    /// Builds and starts the stream. Lock-free: touches no shared state, so
    /// it is safe to await. Returns the running stream for the caller to
    /// publish on outputQueue.
    private func startStream() async -> SCStream? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let pid = NSRunningApplication.current.processIdentifier
            let excluded = content.windows.filter { $0.owningApplication?.processID == pid }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            // Native pixels: the mapping is zero-copy, so full resolution
            // costs no CPU — the shader downsamples naturally. Cursor stays
            // out: a frozen cursor over a live desktop reads as a bug.
            // NSScreen is main-thread-only: resolve the scale on MainActor.
            let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
            let config = SCStreamConfiguration()
            config.width = Int(Double(display.width) * Double(scale))
            config.height = Int(Double(display.height) * Double(scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 2
            config.showsCursor = false
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            return stream
        } catch {
            return nil
        }
    }

    private func stopStream() {
        lock.lock()
        let stream = stream
        lock.unlock()
        guard let stream else { return }
        // stopCapture can stall for seconds (documented WindowServer
        // behavior) — detached background task, never the caller.
        Task.detached(priority: .utility) {
            try? stream.removeStreamOutput(self, type: .screen)
            try? await stream.stopCapture()
        }
        lock.lock()
        self.stream = nil
        running = false
        latestPixelBuffer = nil
        lock.unlock()
    }

    // MARK: - Frame access

    /// Newest frame as a zero-copy Metal texture (IOSurface-backed). The
    /// returned keeper MUST be retained by the caller until its blit
    /// completes — the MTLTexture is an interior reference whose mapping
    /// lives and dies with the CVMetalTexture container. Nil while the
    /// stream warms or on any error: caller falls back to one-shot capture.
    /// Fast: lock + cache lookup only.
    public func takeLatestTexture(device: MTLDevice) -> (texture: MTLTexture, width: Int, height: Int, keeper: CVMetalTexture)? {
        lock.lock()
        guard let pixelBuffer = latestPixelBuffer else {
            lock.unlock()
            return nil
        }
        if cacheDevice == nil || textureCache == nil || !devicesEqual(cacheDevice, device) {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
            cacheDevice = device
        }
        guard let cache = textureCache else {
            lock.unlock()
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard result == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return (texture, width, height, cvTexture)
    }

    private func devicesEqual(_ a: MTLDevice?, _ b: MTLDevice) -> Bool {
        guard let a else { return false }
        return a === b
    }
}

// MARK: - SCStreamOutput + SCStreamDelegate

extension StreamCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // ARC retains the buffer; the previous frame releases here. No copy.
        lock.lock()
        latestPixelBuffer = pixelBuffer
        lock.unlock()
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.running = false
            self.stream = nil
            self.latestPixelBuffer = nil
            self.lock.unlock()
        }
    }
}
