import Foundation
import AppKit

public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()
    
    private var window: NSWindow?
    private var metalView: MetalFoldView?
    private var isCapturing = false
    private var wasZeroTurn = true
    private var sleepObservers: [NSObjectProtocol] = []

    // Clamshell truthfulness: no 3D unfold geometry on open (the real desktop
    // is already there). Open path is a short fade-only handoff.
    private var openFadeFramesRemaining = 0
    private static let openFadeFramesTotal = 5

    // Capture dedupe: skip texture re-upload when the frame is unchanged.
    private var lastCaptureHash: UInt64 = 0
    
    public override init() {
        super.init()
        setupWindow()
        setupSleepObservers()
        
        // Connect intelligent hardware pre-arming
        LidSensor.shared.onPreArmCapture = { [weak self] in
            self?.captureScreenAsync()
        }
    }
    
    private func setupSleepObservers() {
        guard sleepObservers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        sleepObservers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        })
        sleepObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        })
        sleepObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })
        sleepObservers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })
    }

    deinit {
        let ws = NSWorkspace.shared.notificationCenter
        for token in sleepObservers {
            ws.removeObserver(token)
        }
    }
    
    private func handleSleep() {
        hideOverlay()
        AppSettings.shared.isScreenCaptureDormant = true
    }
    
    private func handleWake() {
        wasZeroTurn = true
        if let win = self.window, AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        }
        if AppSettings.shared.imageSourceMode == .liveCapture {
            captureScreenAsync()
        }
    }
    
    private func setupWindow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.canBecomeVisibleWithoutLogin = true
        if AppSettings.shared.enableLockScreenPriority {
            win.level = .init(rawValue: Int(Int32.max - 2))
        } else {
            win.level = .screenSaver
        }
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.alphaValue = 0.0
        
        if AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        }
        
        let mtkView = MetalFoldView(frame: win.contentView?.bounds ?? screen.frame)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.isPaused = true
        win.contentView = mtkView
        
        self.window = win
        self.metalView = mtkView
        
        // One-time initial image load in background during app launch
        Task {
            if let img = await ScreenCapture.shared.fetchImage() {
                let hash = Self.quickHash(img)
                self.lastCaptureHash = hash
                await MainActor.run {
                    self.metalView?.updateImage(img)
                    AppSettings.shared.lastCaptureDate = Date()
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            }
        }
    }
    
    public func update(turn: Double, angle: Double) {
        guard let win = self.window, let mv = self.metalView else { return }

        // External display attached = clamshell desktop mode. The internal panel
        // isn't the workspace — suppress the fold overlay entirely.
        if NSScreen.screens.count > 1 {
            if !wasZeroTurn {
                stopOverlay()
            }
            AppSettings.shared.isScreenCaptureDormant = true
            return
        }
        
        mv.currentTurn = Float(turn)
        mv.blurStrength = Float(AppSettings.shared.blurStrength)
        mv.reflectionIntensity = Float(AppSettings.shared.reflectionIntensity)
        mv.updateFrameRate(turn: Float(turn))
        
        // Only trigger when closing and turn > 0
        if turn > 0.0001 {
            openFadeFramesRemaining = 0
            if wasZeroTurn {
                wasZeroTurn = false
                win.alphaValue = 1.0
                mv.resumeRendering()
                win.orderFrontRegardless()
                if AppSettings.shared.enableLockScreenPriority {
                    SkyLightOperator.shared.delegateWindow(win)
                }
                // If pre-arm hasn't finished or was skipped, trigger snapshot if not already active
                if AppSettings.shared.imageSourceMode == .liveCapture {
                    captureScreenAsync()
                }
            }
            mv.isPaused = false
        } else {
            if !wasZeroTurn {
                // Safe open handoff: fade the frozen frame out over a few ticks
                // instead of revealing 3D unfold geometry that would fight the
                // real desktop. Lock-screen opens are suppressed by handleWake.
                if openFadeFramesRemaining == 0 {
                    openFadeFramesRemaining = Self.openFadeFramesTotal
                }
                if openFadeFramesRemaining > 1 {
                    openFadeFramesRemaining -= 1
                    win.alphaValue = Double(openFadeFramesRemaining) / Double(Self.openFadeFramesTotal)
                    mv.currentTurn = 0.0
                    mv.isPaused = false
                } else {
                    hideOverlay()
                }
            }
        }
    }
    
    public func stopOverlay() {
        hideOverlay()
        metalView?.currentTurn = 0.0
    }

    /// Full hide: remove from the compositor scene graph and release GPU
    /// drawables. alphaValue=0 alone keeps WindowServer compositing a
    /// fullscreen transparent topmost window forever — battery tax.
    private func hideOverlay() {
        wasZeroTurn = true
        openFadeFramesRemaining = 0
        window?.alphaValue = 0.0
        window?.orderOut(nil)
        metalView?.suspendRendering()
    }
    
    public func updateWindowLevel() {
        guard let win = self.window else { return }
        if AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        } else {
            win.level = .screenSaver
        }
    }
    
    public func captureScreenAsync() {
        guard !isCapturing else { return }
        isCapturing = true
        AppSettings.shared.isScreenCaptureDormant = false
        
        Task {
            if let image = await ScreenCapture.shared.fetchImage() {
                let hash = Self.quickHash(image)
                let unchanged = hash == self.lastCaptureHash
                if !unchanged {
                    self.lastCaptureHash = hash
                }
                await MainActor.run {
                    // Skip texture re-upload + mip regen when the frame is unchanged.
                    if !unchanged {
                        self.metalView?.updateImage(image)
                    }
                    self.isCapturing = false
                    AppSettings.shared.lastCaptureDate = Date()
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            } else {
                await MainActor.run {
                    self.isCapturing = false
                    AppSettings.shared.isScreenCaptureDormant = true
                }
            }
        }
    }

    // MARK: - Capture dedupe

    /// Cheap FNV-1a over dimensions + strided pixel samples. Runs off-main inside
    /// the capture Task; ~256 samples regardless of resolution.
    static func quickHash(_ image: CGImage) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_372_096_185
        func mix(_ v: UInt64) {
            hash ^= v
            hash = hash &* 1_099_511_628_211
        }
        mix(UInt64(image.width))
        mix(UInt64(image.height))
        mix(UInt64(image.bytesPerRow))
        guard let provider = image.dataProvider,
              let data = provider.data as Data? else {
            return hash
        }
        let stride = max(1, data.count / 256)
        var i = 0
        while i < data.count {
            mix(UInt64(data[i]))
            i += stride
        }
        return hash
    }
}
