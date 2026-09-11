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
    private var _latestSampleTime: CFTimeInterval = 0
    private var _latestReadOK: Bool = false
    private var _readFailStreak: Int = 0
    private var hidTimer: DispatchSourceTimer?
    
    // Physics and motion tracking
    private var lastTime: CFTimeInterval?
    public private(set) var displayTurn: Double = 0.0
    public private(set) var targetTurn: Double = 0.0
    public private(set) var currentRawAngle: Double = 120.0
    private var isActivelyClosing: Bool = false
    private var hasPreArmedInThisMotion: Bool = false
    private var lastPreArmTime: CFTimeInterval = 0

    // Clamshell truthfulness: smoothed angular velocity (deg/sec, negative = closing).
    // Derived from actual HID sample timestamps — immune to timer-phase aliasing.
    public private(set) var smoothedVelocity: Double = 0.0
    private var prevTickAngle: Double = 120.0
    private var prevConsumedAngle: Double = 120.0
    private var prevConsumedSampleTime: CFTimeInterval = 0
    private var stillSince: CFTimeInterval? = nil

    // Adaptive polling: Feature Reports must be polled (no Input Reports from LAS),
    // so vary the rate instead — 10Hz idle, 60Hz armed, 120Hz while closing.
    private var workspaceObservers: [NSObjectProtocol] = []
    private var currentPollInterval: Double = 1.0 / 60.0
    // Epoch guards the slot against stale fires from a cancelled HID timer:
    // cancel() never interrupts an in-flight handler, so the handler must
    // prove it belongs to the current timer before publishing.
    private var hidPollEpoch: UInt64 = 0
    
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
            // Quiesce sampling, then re-enumerate OFF-main: setupManager
            // blocks on IOHIDManagerOpen + per-device probe GetReports.
            hidTimer?.cancel()
            hidTimer = nil
            let reschedule = (timer != nil)
            let interval = currentPollInterval
            hidQueue.async { [weak self] in
                guard let self else { return }
                self.setupManager()
                self.reopenHIDIfNeeded()
                if reschedule {
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleHIDTimer(interval: interval)
                    }
                }
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
    
    /// Runs bodies on main without deadlocking when already there.
    /// setupManager/probing may run on hidQueue (post-wake) or main (init).
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
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
            hidStateLock.lock()
            self.hidDevice = dev
            hidStateLock.unlock()
            onMain {
                AppSettings.shared.isHardwareSensor = true
                AppSettings.shared.isClamshellMode = false
                AppSettings.shared.isSensorConnected = true
                AppSettings.shared.sensorStatusMessage = "Hardware Lid Angle Sensor connected (PID: 0x\(String(format: "%04X", detectedPid)) - \(detectedProd))."
            }
        } else {
            // Hardware sensor not present on this machine (e.g. MacBook Neo, M1 Air, M1 Pro 13", iMac)
            activateClamshellMode(reason: "MacBook Neo / M1 without continuous LAS hardware")
        }
    }
    
    private func activateClamshellMode(reason: String) {
        hidStateLock.lock()
        self.hidDevice = nil
        self.isDeviceOpen = false
        hidStateLock.unlock()
        let closed = isLidClosedViaIORegistry()
        onMain {
            AppSettings.shared.isHardwareSensor = false
            AppSettings.shared.isClamshellMode = true
            AppSettings.shared.isSensorConnected = true
            AppSettings.shared.sensorStatusMessage = "Clamshell Mode Active (MacBook Neo / M1 — Auto Sleep & Wake Animation Enabled)"
        }
        lastKnownClamshellClosed = closed
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
        // stop() removes wake observers; re-add here (guard is idempotent).
        setupWakeAndSleepObservers()
        // Async open: never block the caller behind an in-flight GetReport.
        hidQueue.async { [weak self] in
            guard let self else { return }
            self.hidStateLock.lock()
            let device = self.hidDevice
            let opened = self.isDeviceOpen
            self.hidStateLock.unlock()
            if let device, !opened,
               IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess {
                self.hidStateLock.lock()
                self.isDeviceOpen = true
                self.hidStateLock.unlock()
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
            // Always .common: easing must not freeze while the user drags a
            // menu or scrolls mid-close (a truthfulness break). Battery comes
            // from tolerance, not the runloop mode — a fresh timer only ever
            // lives in one mode set, and default+re-add cannot downgrade.
            RunLoop.main.add(t, forMode: .common)
            let active = isActivelyClosing || displayTurn > 0.001
            t.tolerance = active ? 0 : interval * 0.2
        }
    }

    private func scheduleHIDTimer(interval: Double) {
        hidTimer?.cancel()
        hidStateLock.lock()
        hidPollEpoch &+= 1
        let epoch = hidPollEpoch
        hidStateLock.unlock()
        let t = DispatchSource.makeTimerSource(queue: hidQueue)
        let leeway: DispatchTimeInterval = isActivelyClosing
            ? .nanoseconds(0)
            : .milliseconds(max(1, Int(interval * 200.0)))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        t.setEventHandler { [weak self] in
            self?.pollHIDOnce(epoch: epoch)
        }
        t.resume()
        hidTimer = t
    }

    /// Blocking Feature Report read. ALWAYS on hidQueue, never main.
    /// Stale fires from a cancelled timer prove epoch before publishing.
    private func pollHIDOnce(epoch: UInt64) {
        hidStateLock.lock()
        let device = hidDevice
        let opened = isDeviceOpen
        let current = hidPollEpoch
        hidStateLock.unlock()
        guard opened, let device, epoch == current else { return }

        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        hidStateLock.lock()
        defer { hidStateLock.unlock() }
        // Re-check epoch: a re-arm may have landed while we blocked.
        guard epoch == hidPollEpoch else { return }
        if result == kIOReturnSuccess, length >= 3 {
            let rawValue = UInt16(report[2]) << 8 | UInt16(report[1])
            _latestRawAngle = Double(rawValue)
            _latestSampleTime = CACurrentMediaTime()
            _latestReadOK = true
            _readFailStreak = 0
        } else {
            _readFailStreak += 1
            if _readFailStreak > 30 {
                _latestReadOK = false
            }
        }
    }

    private func reopenHIDIfNeeded() {
        hidQueue.async { [weak self] in
            guard let self else { return }
            self.hidStateLock.lock()
            let device = self.hidDevice
            let opened = self.isDeviceOpen
            self.hidStateLock.unlock()
            guard let dev = device else { return }
            if opened {
                IOHIDDeviceClose(dev, Self.noOptions)
            }
            let ok = IOHIDDeviceOpen(dev, Self.noOptions) == kIOReturnSuccess
            self.hidStateLock.lock()
            self.isDeviceOpen = ok
            if ok { self._readFailStreak = 0 }
            self.hidStateLock.unlock()
        }
    }

    /// Close onset must not wait for the 2-tick stability gate: a close
    /// starting from 10Hz idle would otherwise lag ~200ms — the exact hitch
    /// users feel. Opening/downward motion kicks 120Hz immediately.
    private func kickHighRateIfNeeded() {
        let fast = 1.0 / 120.0
        guard abs(currentPollInterval - fast) > 0.0001 else { return }
        currentPollInterval = fast
        stableDesiredInterval = fast
        stableIntervalTicks = 0
        scheduleHIDTimer(interval: fast)
        scheduleEaseTimer(interval: fast)
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
        // Async close: never block the caller behind an in-flight GetReport.
        hidQueue.async { [weak self] in
            guard let self else { return }
            self.hidStateLock.lock()
            let device = self.hidDevice
            let opened = self.isDeviceOpen
            self.hidStateLock.unlock()
            if opened, let device {
                IOHIDDeviceClose(device, Self.noOptions)
                self.hidStateLock.lock()
                self.isDeviceOpen = false
                self.hidStateLock.unlock()
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
            let sampleTime = _latestSampleTime
            let readOK = _latestReadOK
            hidStateLock.unlock()

            if !readOK {
                // Sensor silent (sleep/wake gap) — try to re-establish off-main.
                reopenHIDIfNeeded()
            }

            if readOK {
                let nowTick = CACurrentMediaTime()
                // Track direction of movement and velocity
                let delta = angle - prevTickAngle
                let isMovingDownward = delta < -0.4
                let isMovingUpward = delta > 0.6

                // Velocity from ACTUAL sample timestamps, not the poll interval:
                // the HID and ease timers share a rate but not a phase, so one
                // tick may consume 0..2 fresh samples. New sample → honest
                // dt-normalized velocity; stale sample → decay, never zero-spike.
                if sampleTime > prevConsumedSampleTime {
                    if prevConsumedSampleTime > 0 {
                        let dtSample = max(sampleTime - prevConsumedSampleTime, 1.0 / 240.0)
                        let instVelocity = (angle - prevConsumedAngle) / dtSample
                        let clampedInst = min(max(instVelocity, -1200.0), 1200.0)
                        smoothedVelocity += (clampedInst - smoothedVelocity) * 0.25
                    }
                    prevConsumedAngle = angle
                    prevConsumedSampleTime = sampleTime
                } else {
                    smoothedVelocity *= 0.85
                }
                prevTickAngle = angle

                if isMovingDownward {
                    isActivelyClosing = true
                    stillSince = nil
                    kickHighRateIfNeeded()
                } else if isMovingUpward {
                    isActivelyClosing = false
                    hasPreArmedInThisMotion = false
                    stillSince = nil
                } else {
                    // Time-based stillness (200ms), not frame-counted: the
                    // adaptive clock runs 10..120Hz, so frame counts lie.
                    if stillSince == nil {
                        stillSince = nowTick
                    } else if nowTick - stillSince! > 0.2 {
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
