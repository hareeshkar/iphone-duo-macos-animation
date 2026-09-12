import Foundation
import AppKit

public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()
    
    private var window: NSWindow?
    private var metalView: MetalFoldView?
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
    private var foldTask: Task<Void, Never>?
    // Task is a struct (no identity): the generation tells a stale
    // completion not to nil a newer task's handle out from under it.
    private var foldGeneration: UInt64 = 0

    // NSScreen topology cannot change without a display reconfiguration or
    // sleep/wake notification (all observed) — except the lid itself, which
    // drives this very update(). So the cached decision refreshes on those
    // events plus every show transition (once per fold, never per-tick).
    private var suppressForClamshell = false

    /// Recompute suppression. Called on init, reconfiguration, sleep, wake,
    /// and on every show transition (cheap, runs once per fold — closes the
    /// staleness window where a lid-close lands before any notification).
    private func refreshSuppression() {
        let count = NSScreen.screens.count
        suppressForClamshell = count > 1 && Self.isBuiltInPanelAsleepOrGone() && Self.hasBuiltInPanelOnline() && LidSensor.shared.isLidPhysicallyClosed
    }
    
    public override init() {
        super.init()
        setupWindow()
        setupSleepObservers()
        refreshSuppression()
        displayReconfigObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayReconfiguration()
        }

        // Pre-arm warms the stream only. The old full-res one-shot here paid
        // enumeration + decode + upload seconds before the stream hands a
        // fresher frame for free; the kept-across-hide texture covers show.
        LidSensor.shared.onPreArmCapture = { StreamCapture.shared.prime() }
    }

    private func handleDisplayReconfiguration() {
        refreshSuppression()
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
        refreshSuppression()
        if let win = self.window, AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        }
        // Warm the stream for an imminent fold. No one-shot fetch: the kept
        // texture covers, and a wake-time capture races the stream for the
        // generation guard to throw away.
        StreamCapture.shared.prime()
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

        // Best-effort self-exclusion: removes the window from legacy
        // CGWindowList paths. It does NOT exclude SCK display captures on
        // macOS 15.4+ (composited framebuffer is captured regardless — DTS:
        // "no public APIs for preventing screen capture"), so the PID-
        // exclusion filters below remain the load-bearing layer there, plus
        // full cache invalidation on show. ON-DEVICE VERIFICATION: show →
        // capture → confirm no feedback frame on each supported OS.
        win.sharingType = .none
        
        if AppSettings.shared.enableLockScreenPriority {
            SkyLightOperator.shared.delegateWindow(win)
        }
        
        let mtkView = MetalFoldView(frame: win.contentView?.bounds ?? screen.frame)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.isPaused = true
        win.contentView = mtkView
        
        self.window = win
        self.metalView = mtkView
        
        // One-time initial image load in background during app launch.
        // Provenance travels with it: a permissionless-launch wallpaper fill
        // reports non-live, so the show gate re-fetches once live is granted
        // instead of posing wallpaper as desktop.
        Task(priority: .utility) {
            let result = await ScreenCapture.shared.fetchImage()
            if let img = result.image {
                await MainActor.run {
                    self.metalView?.updateImage(img, isLive: result.isLive)
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
        // No builtin anywhere (mini/Studio/Pro): there is no lid to be
        // truthful about — never suppress, so preview still works.
        if suppressForClamshell {
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
                // The lid itself is a topology event no notification precedes:
                // re-resolve suppression here (once per fold) before trusting
                // the cached decision.
                refreshSuppression()
                if suppressForClamshell {
                    AppSettings.shared.isScreenCaptureDormant = true
                    return
                }
                // Cold-texture gate with provenance: never orderFront with no
                // frame, and never with a NON-live frame in live mode (a
                // first-run wallpaper posing as desktop would pop mid-fold
                // when live replaces it). Without recording permission any
                // frame passes — fallback art is the honest best available.
                // If the launch fetch lost its race, fetch now and show on a
                // later tick at the then-current turn — a late correct fold
                // beats a teleport-from-nothing. Re-issues only when no fetch
                // is in flight (no 120Hz fetch thrash).
                let liveMode = AppSettings.shared.imageSourceMode == .liveCapture
                let textureOK = mv.hasTexture
                    && (!liveMode || mv.isLiveTexture || !AppSettings.shared.hasScreenRecordingPermission)
                guard textureOK else {
                    if foldTask == nil {
                        captureScreenAsync()
                    }
                    mv.isPaused = false
                    return
                }
                wasZeroTurn = false
                win.alphaValue = 1.0
                // Full invalidation on show: SCK captures the composited
                // framebuffer regardless of sharingType (15.4+), so a filter
                // rebuilt from a pre-show window list photographs our own
                // just-ordered overlay. Correctness beats the enumeration
                // latency saved by filter-only refresh.
                ScreenCapture.shared.invalidateCaches()
                mv.resumeRendering()
                win.orderFrontRegardless()
                beginOverlayActivity()
                if AppSettings.shared.enableLockScreenPriority {
                    SkyLightOperator.shared.delegateWindow(win)
                }
                // Live mode takes the warm stream frame or captures — one
                // task factory. Frozen-at-show semantics: the frame is taken
                // once here and never refreshed mid-fold, so a video playing
                // underneath can't keep moving inside the fold, and 60Hz
                // stream frames can't step against 120Hz geometry.
                if AppSettings.shared.imageSourceMode == .liveCapture {
                    // Fast path first: a warm stream hands us an IOSurface
                    // frame with zero CPU copies. Cold stream → capture.
                    StreamCapture.shared.noteVisible()
                    if let dev = mv.device,
                       let frame = StreamCapture.shared.takeLatestTexture(device: dev) {
                        mv.updateStreamTexture(frame.texture, width: frame.width, height: frame.height, keeper: frame.keeper)
                    } else {
                        captureScreenAsync()
                    }
                } else {
                    captureScreenAsync()
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

    /// Built-in panel asleep-or-absent from ACTIVE space = genuine clamshell
    /// desktop mode. (Asleep displays stay in display space, so presence
    /// alone proves nothing — sleep state decides.)
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

    /// Laptop-ness gate: the ONLINE list retains sleeping displays, so a
    /// builtin-less desktop Mac (mini/Studio) is distinguishable from a
    /// closed clamshell. Without it, multi-display desktops would suppress
    /// the effect (and its preview) permanently.
    private static func hasBuiltInPanelOnline() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return false }
        for i in 0..<Int(count) {
            if CGDisplayIsBuiltin(displays[i]) != 0 {
                return true
            }
        }
        return false
    }

    private func beginOverlayActivity() {
        if overlayActivity == nil {
            overlayActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "macTilt fold animation visible"
            )
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
        foldTask?.cancel()
        foldTask = nil
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
    
    /// Single texture-reload factory for all modes — and the manual-refresh
    /// entry point for the menu bar and settings panel. One cancellable task;
    /// texture-generation newest-wins arbitrates overlap. Dropping the newest
    /// behind an in-flight fetch once showed stale frames, so we never drop.
    /// Resolution tiered by panel density (1x externals stay full-res).
    /// Main-thread by convention (all call sites audited: tick-driven update,
    /// menu action, SwiftUI control): a trap here would punish a future
    /// background caller in production, while @MainActor would cascade awaits
    /// into the synchronous tick→update hot path that cannot suspend. The
    /// NSScreen read itself is hop-safe inside the @MainActor task below.
    public func captureScreenAsync() {
        foldTask?.cancel()
        AppSettings.shared.isScreenCaptureDormant = false

        // Upload itself is ordered + cheap (background serial queue), so no
        // pixel hashing — the old FNV bridged the full IOSurface-backed Data
        // (7-30MB readback) to "save" an already-backgrounded upload, and
        // strided sampling could alias into stale frames. Always upload.
        // @MainActor-isolated task: the awaits suspend without blocking, and
        // the pattern is Sendable-clean (proven by typecheck, Swift 6 mode).
        // Identity-guarded teardown: a cancelled predecessor runs to
        // completion (fetch isn't cancellation-aware) and must not orphan a
        // newer task by nil-ing the shared handle out from under it. Task is
        // a struct (no ===), so a generation counter arbitrates instead.
        foldGeneration &+= 1
        let generation = foldGeneration
        foldTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let live = AppSettings.shared.imageSourceMode == .liveCapture
            let result: (image: CGImage?, isLive: Bool)
            if live {
                result = await ScreenCapture.shared.fetchImage(scaleFactor: self.captureScaleFactor)
            } else {
                result = await ScreenCapture.shared.fetchImage()
            }
            if let image = result.image {
                self.metalView?.updateImage(image, isLive: result.isLive)
                AppSettings.shared.lastCaptureDate = Date()
            }
            if self.foldGeneration == generation {
                self.foldTask = nil
            }
            AppSettings.shared.isScreenCaptureDormant = true
        }
    }

    /// Capture resolution tier: full pixels on 1x panels (960x540-upscaled
    /// would be a blurry mess side-by-side with the live desktop), half on
    /// Retina where the blur/LOD chain resolves no more. Main-thread only;
    /// read only from main-confined callers (show path, capture factory).
    @MainActor
    private var captureScaleFactor: CGFloat {
        (NSScreen.main?.backingScaleFactor ?? 2.0) <= 1.0 ? 1.0 : 0.5
    }
}
