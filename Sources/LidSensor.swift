import Foundation
import AppKit
import IOKit
import IOKit.hid
import QuartzCore

public final class LidSensor {
    public static let shared = LidSensor()
    
    public typealias TurnCallback = (_ turn: Double, _ angle: Double) -> Void
    public var onTurnUpdate: TurnCallback?
    public var onPreArmCapture: (() -> Void)?
    
    private var hidManager: IOHIDManager?
    private var hidDevice: IOHIDDevice?
    private var isDeviceOpen = false
    private var timer: Timer?
    private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)

    // P0-1: HID I/O lives on its own queue. IOHIDDeviceGetReport blocks on a
    // kernel/SPU round-trip, so it must never run on the main runloop.
    // Main thread keeps easing/interpolation/consumption only.
    private let hidQueue = DispatchQueue(label: "com.mactilt.hid", qos: .userInitiated)
    private let hidStateLock = NSLock()
    private var _latestRawAngle: Double = 120.0
    private var _latestReadOK: Bool = false
    private var _readFailStreak: Int = 0
    private var hidTimer: DispatchSourceTimer?
    
    // Physics and motion tracking
    private var lastTime: CFTimeInterval?
    public private(set) var displayTurn: Double = 0.0
    public private(set) var targetTurn: Double = 0.0
    public private(set) var currentRawAngle: Double = 120.0
    private var previousRawAngle: Double = 120.0
    private var isActivelyClosing: Bool = false
    private var hasPreArmedInThisMotion: Bool = false
    private var lastPreArmTime: CFTimeInterval = 0
    private var stationaryFrames: Int = 0

    // Clamshell truthfulness: smoothed angular velocity (deg/sec, negative = closing).
    // Exposed for velocity-aware blur on the close path. Smoothed to reject HID jitter.
    public private(set) var smoothedVelocity: Double = 0.0

    // Adaptive polling: Feature Reports must be polled (no Input Reports from LAS),
    // so vary the rate instead — 10Hz idle, 60Hz armed, 120Hz while closing.
    private var workspaceObservers: [NSObjectProtocol] = []
    private var currentPollInterval: Double = 1.0 / 60.0
    
    // Clamshell mode animation state (MacBook Neo, M1, etc.)
    private var isSimulating: Bool = false
    private var simulationStartTime: CFTimeInterval = 0
    private var simulationDuration: CFTimeInterval = 0.55
    private var simulationStartTurn: Double = 0.0
    private var simulationTargetTurn: Double = 0.0
    private var simulationStartAngle: Double = 120.0
    private var simulationTargetAngle: Double = 35.0
    private var lastKnownClamshellClosed: Bool = false
    
    private init() {
        setupManager()
        setupWakeAndSleepObservers()
    }
    
    deinit {
        stop()
    }
    
    private func setupWakeAndSleepObservers() {
        guard workspaceObservers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWillSleep()
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWillSleep()
        })
    }

    private func removeWakeAndSleepObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            ws.removeObserver(token)
        }
        workspaceObservers.removeAll()
    }
    
    public func handleWake() {
        if AppSettings.shared.isHardwareSensor {
            // Quiesce sampling before re-enumerating devices (avoids racing
            // setupManager's hidDevice reassignment from the HID queue).
            hidTimer?.cancel()
            hidTimer = nil
            setupManager()
            reopenHIDIfNeeded()
            if timer != nil {
                scheduleHIDTimer(interval: currentPollInterval)
            }
        } else {
            // Clamshell mode: on wake / opening from sleep, animate unfold
            animateUnfold()
        }
    }
    
    public func handleWillSleep() {
        if !AppSettings.shared.isHardwareSensor {
            // Clamshell mode: animate fold on sleep
            animateFold()
        }
    }
    
    private func setupManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        guard IOHIDManagerOpen(manager, Self.noOptions) == kIOReturnSuccess else {
            activateClamshellMode(reason: "IOHIDManager unavailable")
            return
        }
        self.hidManager = manager
        
        // Multi-Strategy Hardware Sensor Probing:
        // STRICTLY match only sensor hardware (UsagePage 0x20, PID 0x8104, "las").
        // NEVER match keyboards or general input to prevent macOS from asking for "Keystroke Receiving" permission.
        let matchingCriteria: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: 0x05AC,
                kIOHIDProductIDKey as String: 0x8104
            ],
            [
                kIOHIDPrimaryUsagePageKey as String: 0x0020,
                kIOHIDPrimaryUsageKey as String: 0x008A
            ],
            [
                kIOHIDDeviceUsagePageKey as String: 0x0020,
                kIOHIDDeviceUsageKey as String: 0x008A
            ],
            [
                kIOHIDProductKey as String: "las"
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingCriteria as CFArray)
        
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            activateClamshellMode(reason: "No sensor HID devices found")
            return
        }
        
        var foundDevice: IOHIDDevice?
        var detectedPid: Int = 0
        var detectedProd: String = ""
        
        for dev in devices {
            let page = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
            let usage = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
            
            // Hard safety guard: Skip any keyboard, mouse, or pointer devices
            if page == 1 { continue }
            
            let prod = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? ""
            let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            
            let isCandidate = prod.lowercased() == "las" ||
                              prod.lowercased().contains("lid") ||
                              prod.lowercased().contains("angle") ||
                              (page == 32 && usage == 138) ||
                              pid == 0x8104
            
            if isCandidate {
                if IOHIDDeviceOpen(dev, Self.noOptions) == kIOReturnSuccess {
                    var testReport = [UInt8](repeating: 0, count: 8)
                    var len: CFIndex = testReport.count
                    let res = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &testReport, &len)
                    IOHIDDeviceClose(dev, Self.noOptions)
                    
                    if res == kIOReturnSuccess && len >= 3 {
                        foundDevice = dev
                        detectedPid = pid
                        detectedProd = prod.isEmpty ? "las" : prod
                        break
                    }
                }
            }
        }
        
        if let dev = foundDevice {
            self.hidDevice = dev
            AppSettings.shared.isHardwareSensor = true
            AppSettings.shared.isClamshellMode = false
            AppSettings.shared.isSensorConnected = true
            AppSettings.shared.sensorStatusMessage = "Hardware Lid Angle Sensor connected (PID: 0x\(String(format: "%04X", detectedPid)) - \(detectedProd))."
        } else {
            // Hardware sensor not present on this machine (e.g. MacBook Neo, M1 Air, M1 Pro 13", iMac)
            activateClamshellMode(reason: "MacBook Neo / M1 without continuous LAS hardware")
        }
    }
    
    private func activateClamshellMode(reason: String) {
        self.hidDevice = nil
        AppSettings.shared.isHardwareSensor = false
        AppSettings.shared.isClamshellMode = true
        AppSettings.shared.isSensorConnected = true
        AppSettings.shared.sensorStatusMessage = "Clamshell Mode Active (MacBook Neo / M1 — Auto Sleep & Wake Animation Enabled)"
        lastKnownClamshellClosed = isLidClosedViaIORegistry()
    }
    
    private func isLidClosedViaIORegistry() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        
        if let prop = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            return prop.boolValue
        }
        return false
    }
    
    // MARK: - Clamshell Mode Simulations (MacBook Neo & M1)
    
    public func animateUnfold() {
        isSimulating = true
        simulationStartTime = CACurrentMediaTime()
        simulationDuration = 0.55
        simulationStartTurn = max(0.85, displayTurn)
        simulationTargetTurn = 0.0
        simulationStartAngle = 35.0
        simulationTargetAngle = 120.0
        AppSettings.shared.isClosing = false
    }
    
    public func animateFold() {
        isSimulating = true
        simulationStartTime = CACurrentMediaTime()
        simulationDuration = 0.45
        simulationStartTurn = displayTurn
        simulationTargetTurn = 0.85
        simulationStartAngle = 120.0
        simulationTargetAngle = 35.0
        AppSettings.shared.isClosing = true
    }
    
    public func triggerPreviewAnimation() {
        animateFold()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.animateUnfold()
        }
    }
    
    public func start() {
        guard timer == nil else { return }
        hidQueue.sync { [weak self] in
            guard let self else { return }
            if let device = self.hidDevice, !self.isDeviceOpen {
                if IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess {
                    self.isDeviceOpen = true
                }
            }
        }
        scheduleHIDTimer(interval: currentPollInterval)
        scheduleEaseTimer(interval: currentPollInterval)
    }

    // MARK: - Dual timers: HID sampling (background) + easing (main)

    private func scheduleEaseTimer(interval: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer {
            // Active closing needs delivery during menu-tracking/scroll (.common);
            // idle parks on .default so tracking doesn't wake us. Tolerance lets
            // the system coalesce idle fires with other timers (battery).
            let closing = isActivelyClosing || displayTurn > 0.001
            RunLoop.main.add(t, forMode: closing ? .common : .default)
            t.tolerance = closing ? 0 : interval * 0.2
        }
    }

    private func scheduleHIDTimer(interval: Double) {
        hidTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: hidQueue)
        let leeway: DispatchTimeInterval = isActivelyClosing
            ? .nanoseconds(0)
            : .milliseconds(max(1, Int(interval * 200.0)))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        t.setEventHandler { [weak self] in
            self?.pollHIDOnce()
        }
        t.resume()
        hidTimer = t
    }

    /// Blocking Feature Report read. ALWAYS on hidQueue, never main.
    /// Writes the latest angle into the lock-guarded slot; tick() consumes.
    private func pollHIDOnce() {
        guard let device = hidDevice else { return }
        hidStateLock.lock()
        let opened = isDeviceOpen
        hidStateLock.unlock()
        guard opened else { return }

        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        hidStateLock.lock()
        if result == kIOReturnSuccess, length >= 3 {
            let rawValue = UInt16(report[2]) << 8 | UInt16(report[1])
            _latestRawAngle = Double(rawValue)
            _latestReadOK = true
            _readFailStreak = 0
        } else {
            _readFailStreak += 1
            if _readFailStreak > 30 {
                _latestReadOK = false
            }
        }
        hidStateLock.unlock()
    }

    private func reopenHIDIfNeeded() {
        hidQueue.async { [weak self] in
            guard let self else { return }
            self.hidStateLock.lock()
            let needsReopen = !self.isDeviceOpen || !self._latestReadOK
            let device = self.hidDevice
            self.hidStateLock.unlock()
            guard needsReopen, let dev = device else { return }
            if self.isDeviceOpen {
                IOHIDDeviceClose(dev, Self.noOptions)
            }
            let ok = IOHIDDeviceOpen(dev, Self.noOptions) == kIOReturnSuccess
            self.hidStateLock.lock()
            self.isDeviceOpen = ok
            if ok { self._readFailStreak = 0 }
            self.hidStateLock.unlock()
        }
    }

    /// Adaptive rate control — called at the end of tick(). Keeps zero-idle-cost
    /// promise: 10Hz when parked open, 60Hz when armed, 120Hz while closing.
    /// Re-arms both timers only on stable transitions (no runloop churn).
    private var stableDesiredInterval: Double = 1.0 / 60.0
    private var stableIntervalTicks: Int = 0
    private func adaptPollInterval(angle: Double) {
        let settings = AppSettings.shared
        let desired: Double
        if isActivelyClosing {
            desired = 1.0 / 120.0
        } else if !settings.isScreenCaptureDormant || angle <= min(135.0, settings.startTiltAngle + 15.0) || displayTurn > 0.001 {
            desired = 1.0 / 60.0
        } else {
            desired = 1.0 / 10.0
        }
        if abs(desired - stableDesiredInterval) > 0.0001 {
            stableDesiredInterval = desired
            stableIntervalTicks = 0
        } else {
            stableIntervalTicks += 1
        }
        if stableIntervalTicks == 2, abs(desired - currentPollInterval) > 0.0001 {
            currentPollInterval = desired
            scheduleHIDTimer(interval: desired)
            scheduleEaseTimer(interval: desired)
        }
    }
    
    public func stop() {
        timer?.invalidate()
        timer = nil
        hidTimer?.cancel()
        hidTimer = nil
        removeWakeAndSleepObservers()
        hidQueue.sync { [weak self] in
            guard let self else { return }
            if self.isDeviceOpen, let device = self.hidDevice {
                IOHIDDeviceClose(device, Self.noOptions)
                self.isDeviceOpen = false
            }
        }
    }
    
    private func tick() {
        let settings = AppSettings.shared
        
        if settings.isHardwareSensor {
            // Consume the latest angle sampled on hidQueue. Main thread never
            // blocks on the kernel here — worst case we reuse last tick's value.
            hidStateLock.lock()
            let angle = _latestRawAngle
            let readOK = _latestReadOK
            hidStateLock.unlock()

            if !readOK {
                // Sensor silent (sleep/wake gap) — try to re-establish off-main.
                reopenHIDIfNeeded()
            }

            if readOK {
                // Track direction of movement and velocity
                let delta = angle - previousRawAngle
                let isMovingDownward = delta < -0.4
                let isMovingUpward = delta > 0.6

                // Smoothed angular velocity (deg/sec) for velocity-aware blur.
                // Clamped to reject HID spikes; decays to zero when stationary.
                let instVelocity = delta / max(currentPollInterval, 1.0 / 240.0)
                let clampedInst = min(max(instVelocity, -1200.0), 1200.0)
                smoothedVelocity += (clampedInst - smoothedVelocity) * 0.25
                if !isMovingDownward && !isMovingUpward {
                    smoothedVelocity *= 0.85
                }

                if isMovingDownward {
                    isActivelyClosing = true
                    stationaryFrames = 0
                } else if isMovingUpward {
                    isActivelyClosing = false
                    hasPreArmedInThisMotion = false
                    stationaryFrames = 0
                } else {
                    stationaryFrames += 1
                    if stationaryFrames > 12 { // ~200ms of no downward movement
                        isActivelyClosing = false
                    }
                }

                // If lid is safely open, reset pre-arm latch and mark capture engine dormant
                if angle >= settings.startTiltAngle || (!isActivelyClosing && angle >= settings.startTiltAngle - 10.0) {
                    hasPreArmedInThisMotion = false
                    settings.isScreenCaptureDormant = true
                }

                // Hardware Pre-Arming Capture Zone (widened: capture is cheap now)
                let nowTime = CACurrentMediaTime()
                let preArmThreshold = min(140.0, settings.startTiltAngle + 25.0)
                if angle <= preArmThreshold && angle < settings.startTiltAngle {
                    if !hasPreArmedInThisMotion && (nowTime - lastPreArmTime > 2.0) {
                        hasPreArmedInThisMotion = true
                        lastPreArmTime = nowTime
                        settings.isScreenCaptureDormant = false
                        onPreArmCapture?()
                    }
                }

                previousRawAngle = angle
                currentRawAngle = angle
                settings.currentLidAngle = angle
                settings.isClosing = isActivelyClosing
                settings.isSensorConnected = true
            }
            
            // Compute target turn: continuously mirrors physical angle across full range
            targetTurn = settings.normalizedTurn(for: currentRawAngle)
            
            // Follow easing physics
            let now = CACurrentMediaTime()
            let dt: Double
            if let last = lastTime {
                dt = min(now - last, 0.1)
            } else {
                dt = 1.0 / 60.0
            }
            lastTime = now
            
            let follow = settings.followSpeed
            let factor = 1.0 - exp(-dt * follow)
            displayTurn += (targetTurn - displayTurn) * factor
            if abs(targetTurn - displayTurn) < 0.0005 {
                displayTurn = targetTurn
            }
        } else {
            // Clamshell Mode (MacBook Neo, M1, etc.)
            let currentClosed = isLidClosedViaIORegistry()
            if currentClosed != lastKnownClamshellClosed {
                lastKnownClamshellClosed = currentClosed
                if currentClosed {
                    animateFold()
                } else {
                    animateUnfold()
                }
            }
            
            if isSimulating {
                let elapsed = CACurrentMediaTime() - simulationStartTime
                let t = min(1.0, elapsed / simulationDuration)
                // Smooth cubic ease out
                let ease = 1.0 - pow(1.0 - t, 3.0)
                displayTurn = simulationStartTurn + (simulationTargetTurn - simulationStartTurn) * ease
                currentRawAngle = simulationStartAngle + (simulationTargetAngle - simulationStartAngle) * ease
                settings.currentLidAngle = currentRawAngle
                
                if t >= 1.0 {
                    isSimulating = false
                    displayTurn = simulationTargetTurn
                    currentRawAngle = simulationTargetAngle
                    settings.currentLidAngle = currentRawAngle
                }
            } else if settings.isTestModeActive {                displayTurn = settings.normalizedTurn(for: 120.0)
                currentRawAngle = 120.0 - displayTurn * 85.0
                settings.currentLidAngle = currentRawAngle
            } else {
                displayTurn = 0.0
                currentRawAngle = 120.0
                settings.currentLidAngle = 120.0
            }
        }
        
        adaptPollInterval(angle: currentRawAngle)
        onTurnUpdate?(displayTurn, currentRawAngle)
    }
}
