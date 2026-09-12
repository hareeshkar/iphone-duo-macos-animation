import Foundation
import Combine
import SwiftUI

public enum FeelPreset: Int, CaseIterable, Identifiable {
    case gentle = 0
    case balanced = 1
    case sharp = 2
    case custom = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .gentle: return "Gentle"
        case .balanced: return "Balanced"
        case .sharp: return "Sharp"
        case .custom: return "Custom"
        }
    }

    /// Joint follow/blur/shine recipe. Follow and prediction lead stay
    /// coupled by construction (lead derives from follow in LidSensor), so
    /// no preset can decouple tracking bandwidth from anticipation into
    /// floaty-fake territory. Values validated in the physics review; Gentle
    /// sits at 13 (inside the lead formula's exact band, and out of the
    /// "snappy" suffix band so the label never contradicts the preset).
    public var recipe: (follow: Double, blur: Double, shine: Double) {
        switch self {
        case .gentle: return (13.0, 0.8, 0.4)
        case .balanced: return (16.0, 0.5, 0.0)
        case .sharp: return (24.0, 0.2, 0.0)
        case .custom: return (16.0, 0.5, 0.0)
        }
    }
}
public enum ImageSourceMode: Int, CaseIterable, Identifiable {
    case liveCapture = 0
    case desktopWallpaper = 1
    case bundledArtwork = 2
    case customImage = 3
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .liveCapture: return "My Open Windows"
        case .desktopWallpaper: return "My Wallpaper"
        case .bundledArtwork: return "Included Art"
        case .customImage: return "My Own Photo"
        }
    }

    public var help: String {
        switch self {
        case .liveCapture: return "Bends your real open windows. Needs Screen Permission above."
        case .desktopWallpaper: return "Bends your current desktop picture. No permission needed."
        case .bundledArtwork: return "Bends the art included with macTilt. No permission needed."
        case .customImage: return "Bends any photo you pick on your Mac."
        }
    }
}

public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    
    // MARK: - Persistent User Defaults Keys
    private let kStartTiltAngle = "mactilt_startTiltAngle"
    private let kEndTiltAngle = "mactilt_endTiltAngle"
    private let kFollowSpeed = "mactilt_followSpeed"
    private let kImageSourceMode = "mactilt_imageSourceMode"
    private let kCustomImagePath = "mactilt_customImagePath"
    private let kBlurStrength = "mactilt_blurStrength"
    private let kReflectionIntensity = "mactilt_reflectionIntensity"
    private let kShowAngleInMenuBar = "mactilt_showAngleInMenuBar"
    private let kEnableLockScreenPriority = "mactilt_enable_lock_screen_priority"
    private let kHasCompletedOnboarding = "mactilt_hasCompletedOnboarding"
    private let kAutomaticallyCheckForUpdates = "mactilt_automaticallyCheckForUpdates"
    private let kFeelPreset = "mactilt_feelPreset"
    private let kEnableWarmStream = "mactilt_enableWarmStream"
    
    // MARK: - Customizable Animation Options
    @Published public var automaticallyCheckForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyCheckForUpdates, forKey: kAutomaticallyCheckForUpdates) }
    }
    
    @Published public var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: kHasCompletedOnboarding) }
    }
    
    @Published public var startTiltAngle: Double {
        didSet { UserDefaults.standard.set(startTiltAngle, forKey: kStartTiltAngle) }
    }
    
    @Published public var endTiltAngle: Double {
        didSet { UserDefaults.standard.set(endTiltAngle, forKey: kEndTiltAngle) }
    }
    
    @Published public var followSpeed: Double {
        didSet { UserDefaults.standard.set(followSpeed, forKey: kFollowSpeed) }
    }
    
    @Published public var imageSourceMode: ImageSourceMode {
        didSet { UserDefaults.standard.set(imageSourceMode.rawValue, forKey: kImageSourceMode) }
    }
    
    @Published public var customImagePath: String {
        didSet { UserDefaults.standard.set(customImagePath, forKey: kCustomImagePath) }
    }
    
    @Published public var blurStrength: Double {
        didSet { UserDefaults.standard.set(blurStrength, forKey: kBlurStrength) }
    }
    
    @Published public var reflectionIntensity: Double {
        didSet { UserDefaults.standard.set(reflectionIntensity, forKey: kReflectionIntensity) }
    }
    
    @Published public var showAngleInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showAngleInMenuBar, forKey: kShowAngleInMenuBar)
            MenuBarController.shared.refreshMenuBarTitle()
        }
    }
    
    @Published public var enableLockScreenPriority: Bool {
        didSet {
            UserDefaults.standard.set(enableLockScreenPriority, forKey: kEnableLockScreenPriority)
            OverlayWindowController.shared.updateWindowLevel()
        }
    }

    @Published public var feelPreset: FeelPreset {
        didSet { UserDefaults.standard.set(feelPreset.rawValue, forKey: kFeelPreset) }
    }

    @Published public var enableWarmStream: Bool {
        didSet {
            UserDefaults.standard.set(enableWarmStream, forKey: kEnableWarmStream)
            StreamCapture.fastPathEnabled = enableWarmStream
        }
    }

    /// Apply a feel preset's joint recipe. Presets are starting points, never
    /// locks: any later slider move reconciles the badge via reconcilePreset.
    public func applyFeelPreset(_ preset: FeelPreset) {
        guard preset != .custom else { return }
        let recipe = preset.recipe
        followSpeed = recipe.follow
        blurStrength = recipe.blur
        reflectionIntensity = recipe.shine
        feelPreset = preset
    }

    /// Reconcile the preset badge with actual slider values. Value-based, not
    /// flag-based: a suppression flag races SwiftUI's async onChange delivery
    /// (stale closures see the old flag; the async clear opens a flip window),
    /// while values cannot lie. Epsilon compare: slider-stepped doubles can
    /// differ from literals by 1 ulp.
    public func reconcilePreset() {
        for preset in [FeelPreset.gentle, .balanced, .sharp] {
            let r = preset.recipe
            if abs(followSpeed - r.follow) < 1e-9,
               abs(blurStrength - r.blur) < 1e-9,
               abs(reflectionIntensity - r.shine) < 1e-9 {
                if feelPreset != preset { feelPreset = preset }
                return
            }
        }
        if feelPreset != .custom { feelPreset = .custom }
    }
    
    // MARK: - Real-time State
    @Published public var isTestModeActive: Bool = false {
        didSet {
            if !isTestModeActive {
                testTurnValue = 0.0
            }
        }
    }
    @Published public var testTurnValue: Double = 0.0
    @Published public var currentLidAngle: Double = 120.0
    @Published public var isSensorConnected: Bool = false
    @Published public var isHardwareSensor: Bool = false
    @Published public var isClamshellMode: Bool = false
    @Published public var isClosing: Bool = false
    @Published public var sensorStatusMessage: String = "Initializing sensor..."
    @Published public var hasScreenRecordingPermission: Bool = false
    @Published public var lastCaptureDate: Date? = nil
    @Published public var isScreenCaptureDormant: Bool = true

    private var appActiveObserver: NSObjectProtocol?
    
    private init() {
        let defaults = UserDefaults.standard
        
        // Defaults matching User Preferences
        self.hasCompletedOnboarding = defaults.bool(forKey: kHasCompletedOnboarding)
        self.startTiltAngle = defaults.object(forKey: kStartTiltAngle) != nil ? defaults.double(forKey: kStartTiltAngle) : 115.0
        self.endTiltAngle = defaults.object(forKey: kEndTiltAngle) != nil ? defaults.double(forKey: kEndTiltAngle) : 3.0
        self.followSpeed = defaults.object(forKey: kFollowSpeed) != nil ? defaults.double(forKey: kFollowSpeed) : 16.0
        
        let savedSource = defaults.integer(forKey: kImageSourceMode)
        self.imageSourceMode = defaults.object(forKey: kImageSourceMode) != nil ? (ImageSourceMode(rawValue: savedSource) ?? .liveCapture) : .liveCapture
        
        self.customImagePath = defaults.string(forKey: kCustomImagePath) ?? ""
        self.blurStrength = defaults.object(forKey: kBlurStrength) != nil ? defaults.double(forKey: kBlurStrength) : 0.5
        self.reflectionIntensity = defaults.object(forKey: kReflectionIntensity) != nil ? defaults.double(forKey: kReflectionIntensity) : 0.0
        
        self.showAngleInMenuBar = defaults.object(forKey: kShowAngleInMenuBar) != nil ? defaults.bool(forKey: kShowAngleInMenuBar) : true
        self.enableLockScreenPriority = defaults.object(forKey: kEnableLockScreenPriority) != nil ? defaults.bool(forKey: kEnableLockScreenPriority) : true
        self.automaticallyCheckForUpdates = defaults.object(forKey: kAutomaticallyCheckForUpdates) != nil ? defaults.bool(forKey: kAutomaticallyCheckForUpdates) : true

        let savedPreset = defaults.integer(forKey: kFeelPreset)
        self.feelPreset = defaults.object(forKey: kFeelPreset) != nil ? (FeelPreset(rawValue: savedPreset) ?? .balanced) : .balanced

        self.enableWarmStream = defaults.object(forKey: kEnableWarmStream) != nil ? defaults.bool(forKey: kEnableWarmStream) : true
        StreamCapture.fastPathEnabled = self.enableWarmStream
        
        // Listen for app becoming active to re-check permissions immediately
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPermissions()
        }
        
        refreshPermissions()
    }

    deinit {
        if let token = appActiveObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }
    
    public func refreshPermissions() {
        // Fast synchronous check
        let syncStatus = ScreenCapture.shared.hasPermission()
        self.hasScreenRecordingPermission = syncStatus
        
        // Asynchronous active probe via ScreenCaptureKit
        Task {
            let verified = await ScreenCapture.shared.verifyPermissionAsync()
            await MainActor.run {
                self.hasScreenRecordingPermission = verified
            }
        }
    }
    
    /// Calculate normalized turn (0.0 to 1.0) across the entire folding range (closing, opening, or stopped)
    public func normalizedTurn(for angle: Double) -> Double {
        if isTestModeActive {
            return min(1.0, max(0.0, testTurnValue))
        }
        
        // Lid is open at or beyond start tilt angle: flat / no fold
        if angle >= startTiltAngle {
            return 0.0
        }
        
        // Lid is fully closed at or below end tilt angle: full fold
        if angle <= endTiltAngle {
            return 1.0
        }
        
        let range = startTiltAngle - endTiltAngle
        guard range > 0.001 else { return 0.0 }
        
        let rawProgress = (startTiltAngle - angle) / range
        return min(1.0, max(0.0, rawProgress))
    }
}
