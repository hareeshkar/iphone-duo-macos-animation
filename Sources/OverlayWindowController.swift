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

    // Show-triggered reload task: cancellable so a hide mid-capture can't
    // strand a texture publish into a hidden view.
    private var ensureTask: Task<Void, Never>?

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

        // Connect intelligent hardware pre-arming: warm the stream AND take a
        // one-shot so the first show has a frame however it arrives.
        LidSensor.shared.onPreArmCapture = { [weak self] in
            StreamCapture.shared.prime()
            self?.captureScreenAsync(fullResolution: true)
        }
    }

    private func handleDisplayReconfiguration() {
        cachedScreenCount = NSScreen.screens.count
        // Mode changes reuse displayIDs with new geometry — cached filters lie.
        ScreenCapture.shared.invalidateCaches()
        StreamCapture.shared.restart()
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
        // Warm the stream for an imminent fold; refresh the parked texture.
        StreamCapture.shared.prime()
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
        // AND the built-in panel asleep-or-gone. Mirrored presenting (panel
        // awake) keeps the effect — the lid is still physically closing.
        // NOTE: the primitive must be the BUILT-IN panel, not CGMainDisplayID:
        // in clamshell the menu bar (and "main") migrates to the external,
        // awake display, so a main-display sleep test is dead code there.
        if cachedScreenCount > 1 && Self.isBuiltInPanelAsleepOrGone() {
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
                // Fresh content AND filter: content cached up to 5s may predate
                // the just-ordered overlay, and the cached filter's exclusion
                // list then can't exclude it — the capture would photograph
                // our own frozen frame. Both caches drop on show.
                ScreenCapture.shared.invalidateCaches()
                mv.resumeRendering()
                win.orderFrontRegardless()
                beginOverlayActivity()
                if AppSettings.shared.enableLockScreenPriority {
                    SkyLightOperator.shared.delegateWindow(win)
                }
                // Non-live modes need their (instant) texture; live mode goes
                // through the guarded capture path below — never both (double
                // SCK enumeration + double capture per show).
                if AppSettings.shared.imageSourceMode == .liveCapture {
                    // Fast path first: a warm stream hands us an IOSurface
                    // frame with zero CPU copies. Cold stream → one-shot.
                    StreamCapture.shared.noteVisible()
                    if let dev = mv.device,
                       let frame = StreamCapture.shared.takeLatestTexture(device: dev) {
                        mv.updateStreamTexture(frame.texture, width: frame.width, height: frame.height, keeper: frame.keeper)
                    } else {
                        captureScreenAsync(fullResolution: turn < 0.2)
                    }
                } else {
                    ensureTexture()
                }
            }
            mv.isPaused = false
        } else if turn < 0.0001 {
            if !wasZeroTurn {
                // Safe open handoff: TIME-based fade (90ms) of the frozen frame
                // over the live desktop. The real desktop is already there —
                // no 3D unfold geometry to fight it. Pin 60Hz through the fade:
                // after stillness the ease clock may have decayed to 10Hz,
                // which would quantize the fade into a single hard cut.
                let now = CACurrentMediaTime()
                if openFadeDeadline == 0 {
                    openFadeDeadline = now + Self.openFadeDuration
                    LidSensor.shared.pinRate(1.0 / 60.0, for: Self.openFadeDuration + 0.05)
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

    /// Built-in panel asleep-or-absent = genuine clamshell desktop mode.
    /// Enumerates the ACTIVE display list for the built-in panel explicitly:
    /// asleep sleeping displays stay in display space, and in clamshell the
    /// internal panel is asleep (or removed) while the external is awake.
    private static func isBuiltInPanelAsleepOrGone() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return false }
        for i in 0..<Int(count) {
            if CGDisplayIsBuiltin(displays[i]) != 0 {
                return CGDisplayIsAsleep(displays[i]) != 0
            }
        }
        // No built-in panel in display space (closed clamshell) → suppress.
        return true
    }

    private func beginOverlayActivity() {
        if overlayActivity == nil {
            overlayActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "macTilt fold animation visible"
            )
        }
    }

    /// Reload the fold texture when suspend dropped it. Folded into the
    /// guarded capture path: concurrent show-triggered fetches share
    /// isCapturing instead of racing two SCK enumerations per show.
    /// Non-live modes only — live capture flows through captureScreenAsync.
    private func ensureTexture() {
        guard let mv = metalView, !mv.hasTexture, !isCapturing else { return }
        isCapturing = true
        // @MainActor-isolated task: no cross-actor self capture. The await
        // suspends (never blocks main); updateImage backgrounds decode/upload
        // onto the .utility upload queue internally.
        ensureTask?.cancel()
        ensureTask = Task { @MainActor [weak self] in
            if let img = await ScreenCapture.shared.fetchImage() {
                self?.metalView?.updateImage(img)
            }
            self?.isCapturing = false
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
        ensureTask?.cancel()
        ensureTask = nil
        StreamCapture.shared.noteHidden()
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
        // No drop-newest guard: concurrent fetches are rare (show + pre-arm,
        // throttled), uploads serialize on the upload queue, and the texture
        // generation guard publishes newest-wins. Dropping the show-triggered
        // capture while a pre-arm fetch was in flight showed stale frames.
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
