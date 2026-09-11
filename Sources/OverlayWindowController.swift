import Foundation
import AppKit

public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()
    
    private var window: NSWindow?
    private var metalView: MetalFoldView?
    private var isCapturing = false
    private var wasZeroTurn = true
    private var sleepObservers: [NSObjectProtocol] = []
    private var displayReconfigObserver: NSObjectProtocol?

    // Clamshell truthfulness: no 3D unfold geometry on open (the real desktop
    // is already there). Open path is a short TIME-based fade-only handoff —
    // frame-counted fades swing 40ms..500ms across the 10..120Hz clock.
    private var openFadeDeadline: CFTimeInterval = 0
    private static let openFadeDuration: CFTimeInterval = 0.09

    // Scoped anti-nap: held only while the fold is visible, never at idle.
    private var overlayActivity: NSObjectProtocol?

    // NSScreen.screens IPCs per call — cache, refresh on reconfiguration.
    private var cachedScreenCount: Int = 1
    
    public override init() {
        super.init()
        setupWindow()
        setupSleepObservers()
        cachedScreenCount = NSScreen.screens.count
        displayReconfigObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayReconfiguration()
        }

        // Connect intelligent hardware pre-arming
        LidSensor.shared.onPreArmCapture = { [weak self] in
            self?.captureScreenAsync(fullResolution: true)
        }
    }

    private func handleDisplayReconfiguration() {
        cachedScreenCount = NSScreen.screens.count
        // Mode changes reuse displayIDs with new geometry — cached filters lie.
        ScreenCapture.shared.invalidateCaches()
        // Refit the overlay to the (possibly new) main screen geometry.
        if let win = window, let screen = NSScreen.main ?? NSScreen.screens.first {
            win.setFrame(screen.frame, display: false)
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
        if let token = displayReconfigObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let activity = overlayActivity {
            ProcessInfo.processInfo.endActivity(activity)
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
        Task(priority: .utility) {
            if let img = await ScreenCapture.shared.fetchImage() {
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

        // Suppress only for genuine clamshell desktop mode: external attached
        // AND the internal panel asleep. Mirrored presenting (panel awake)
        // keeps the effect — the lid is still physically closing.
        if cachedScreenCount > 1 && Self.isInternalDisplayAsleep() {
            if !wasZeroTurn {
                stopOverlay()
            }
            AppSettings.shared.isScreenCaptureDormant = true
            return
        }

        mv.currentTurn = Float(turn)
        mv.blurStrength = Float(AppSettings.shared.blurStrength)
        mv.reflectionIntensity = Float(AppSettings.shared.reflectionIntensity)
        // Snapshot velocity on main: draw() must never read LidSensor off-main.
        mv.motionBoost = MetalFoldView.velocityBlurBoost()

        // Hysteresis: show above 0.0005, hide below 0.0001. Kills
        // WindowServer scene-graph flapping from HID jitter near open.
        if turn > 0.0005 {
            openFadeDeadline = 0
            if wasZeroTurn {
                wasZeroTurn = false
                win.alphaValue = 1.0
                // Fresh filter: windows created since the cache (including our
                // own overlay) must be in the exclusion list, or the capture
                // photographs our last frozen frame — feedback loop.
                ScreenCapture.shared.invalidateFilterCache()
                mv.resumeRendering()
                win.orderFrontRegardless()
                beginOverlayActivity()
                if AppSettings.shared.enableLockScreenPriority {
                    SkyLightOperator.shared.delegateWindow(win)
                }
                ensureTexture()
                // If pre-arm hasn't finished or was skipped, trigger snapshot if not already active
                if AppSettings.shared.imageSourceMode == .liveCapture {
                    captureScreenAsync(fullResolution: turn < 0.2)
                }
            }
            mv.isPaused = false
        } else if turn < 0.0001 {
            if !wasZeroTurn {
                // Safe open handoff: TIME-based fade (90ms) of the frozen frame
                // over the live desktop. The real desktop is already there —
                // no 3D unfold geometry to fight it.
                let now = CACurrentMediaTime()
                if openFadeDeadline == 0 {
                    openFadeDeadline = now + Self.openFadeDuration
                }
                if now < openFadeDeadline {
                    let remaining = (openFadeDeadline - now) / Self.openFadeDuration
                    win.alphaValue = max(0.0, min(1.0, remaining))
                    mv.currentTurn = 0.0
                    mv.isPaused = false
                } else {
                    hideOverlay()
                }
            }
        }
        // Between thresholds: hold last state (hysteresis band), no flapping.
    }

    /// The internal panel is asleep while an external display drives the
    /// desktop — the definition of clamshell mode worth suppressing for.
    private static func isInternalDisplayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    private func beginOverlayActivity() {
        if overlayActivity == nil {
            overlayActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "macTilt fold animation visible"
            )
        }
    }

    /// suspendRendering nils the texture — reload it on show so the fold
    /// never renders an empty frame.
    private func ensureTexture() {
        guard let mv = metalView, !mv.hasTexture else { return }
        // @MainActor-isolated task: no cross-actor self capture. The await
        // suspends (never blocks main); updateImage backgrounds decode/upload
        // onto the .utility upload queue internally.
        Task { @MainActor [weak self] in
            if let img = await ScreenCapture.shared.fetchImage() {
                self?.metalView?.updateImage(img)
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
        openFadeDeadline = 0
        window?.alphaValue = 0.0
        window?.orderOut(nil)
        metalView?.suspendRendering()
        if let activity = overlayActivity {
            ProcessInfo.processInfo.endActivity(activity)
            overlayActivity = nil
        }
    }
    
    public func updateWindowLevel() {
        guard let win = self.window else { return }
        if AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        } else {
            win.level = .screenSaver
        }
    }
    
    public func captureScreenAsync(fullResolution: Bool = false) {
        guard !isCapturing else { return }
        isCapturing = true
        AppSettings.shared.isScreenCaptureDormant = false

        // Utility QoS: throughput work. Upload itself is ordered + cheap now,
        // so no pixel hashing — the old FNV bridged the full IOSurface-backed
        // Data (7-30MB readback) to "save" an already-backgrounded upload,
        // and strided sampling could alias into stale frames. Always upload.
        Task(priority: .utility) {
            if let image = await ScreenCapture.shared.fetchImage(scaleFactor: fullResolution ? 1.0 : 0.5) {
                await MainActor.run {
                    self.metalView?.updateImage(image)
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
}
