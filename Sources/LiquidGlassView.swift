import SwiftUI
import AppKit

// Adaptive systemGray6 matching Apple HCI for macOS dark/light mode
private let cardBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.14, green: 0.14, blue: 0.16, alpha: 1.0) // macOS systemGray6 dark
        : NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0) // macOS systemGray6 light
}))

private let cardBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1.0, alpha: 0.08)
        : NSColor(white: 0.0, alpha: 0.08)
}))

public struct LiquidGlassControlPanel: View {
    @ObservedObject var settings: AppSettings = AppSettings.shared
    @ObservedObject var updater: UpdateChecker = UpdateChecker.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copiedResetCommand: Bool = false
    @State private var showingPermissionTroubleshooting: Bool = false
    @State private var isApplyingPreset = false
    private let resetCommand = "tccutil reset ScreenCapture com.lqsky7.mactilt"
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // Top Header Bar
            headerBar
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)
            
            Divider()
            
            // Main Settings Scroll Area (All cards match exactly in horizontal width)
            ScrollView {
                VStack(spacing: 14) {
                    // Screen Recording Permission Card
                    permissionCard
                    
                    // Battery & Performance Card
                    batteryCard
                    
                    // Tilt Trigger Angles Card
                    tiltCard
                    
                    // Display Source & Menu Bar Card
                    displaySourceCard
                    
                    // Animation Physics & Shaders Card
                    animationPhysicsCard
                    
                    // Lock Screen & Sleep Wake Card (Optional)
                    lockScreenCard
                    
                    // Interactive Test Slider Card
                    testPreviewCard
                    
                    // Software Updates & Release Card
                    softwareUpdateCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            
            Divider()
            
            // Bottom Action Footer
            footerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 500, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            settings.refreshPermissions()
        }
        .onDisappear {
            settings.isTestModeActive = false
            settings.testTurnValue = 0.0
            OverlayWindowController.shared.stopOverlay()
        }
    }
    
    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cardBackground)
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(cardBorder, lineWidth: 0.5)
                    )
                
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(settings.isSensorConnected ? Color.accentColor : Color.secondary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("macTilt")
                    .font(.title3)
                    .fontWeight(.bold)

                Text("Animation when you close your MacBook")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Real-time Hardware Angle Badge
            HStack(spacing: 8) {
                Circle()
                    .fill(settings.isSensorConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(settings.currentLidAngle))° lid angle")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(angleStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Lid is \(angleStatusText.lowercased()) at \(Int(settings.currentLidAngle)) degrees")
            .help("Your lid's current angle")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(cardBorder, lineWidth: 0.5)
            )
        }
    }
    
    private var angleStatusText: String {
        if settings.currentLidAngle >= settings.startTiltAngle {
            return "Open — using your Mac"
        } else if settings.currentLidAngle <= settings.endTiltAngle {
            return "Closed"
        } else {
            let pct = Int(settings.normalizedTurn(for: settings.currentLidAngle) * 100)
            return "Closing… \(pct)%"
        }
    }
    
    // MARK: - Screen Recording Permission Card
    private var permissionCard: some View {
        HCISectionCard(title: "Screen Recording Permission", icon: "video.badge.checkmark") {
            HStack(spacing: 10) {
                Image(systemName: settings.hasScreenRecordingPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.hasScreenRecordingPermission ? Color.green : Color.orange)
                    .font(.system(size: 15))
                
                Text(settings.hasScreenRecordingPermission ? "Allowed — animation can use your screen" : "Not allowed yet — animation is off")
                    .font(.subheadline)
                    .fontWeight(.medium)

                InfoButton("Screen Recording", content: "Lets macTilt picture your open desktop so it can bend it as you close the lid. Everything stays on this Mac.")

                Spacer()

                Button {
                    settings.refreshPermissions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Check again for permission")

                if !settings.hasScreenRecordingPermission {
                    Button("Allow in System Settings…") {
                        if !ScreenCapture.shared.requestPermission() {
                            ScreenCapture.shared.openSettings()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            settings.refreshPermissions()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    
                    Button {
                        showingPermissionTroubleshooting.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Fix permission problems")
                    .popover(isPresented: $showingPermissionTroubleshooting, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Still says “not allowed”?")
                                .font(.headline)

                            Text("If you already switched it on in System Settings, macOS needs you to quit and reopen macTilt once.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("Quit and Reopen macTilt") {
                                    ScreenCapture.shared.relaunchApp()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button(copiedResetCommand ? "Copied!" : "Copy Fix Command") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(resetCommand, forType: .string)
                                    copiedResetCommand = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        copiedResetCommand = false
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            
                            Text("For experts only — paste in Terminal if nothing else works:")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(resetCommand)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(6)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(14)
                        .frame(width: 300)
                    }
                }
            }
        }
    }
    
    // MARK: - Battery & Power Optimization Card
    private var batteryCard: some View {
        HCISectionCard(title: "Battery & Performance", icon: "battery.100.bolt") {
            VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                
                Text("No battery use while you work")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.green)

                InfoButton("Battery Efficiency", content: "macTilt does nothing while you work. It wakes only the instant you start closing the lid, then sleeps again.")

                Spacer()

                Text(settings.isScreenCaptureDormant ? "Resting" : "Waking up…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }

            Divider()

            // Warm capture toggle row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Instant first frame")
                        .font(.subheadline)
                    Text("Keeps the camera warm so the bend starts at once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                InfoButton("Instant First Frame", content: "Keeps a quiet background capture running near closing time, so the first bent frame appears instantly. Turn off to save a little battery.")

                Spacer()

                Toggle("", isOn: $settings.enableWarmStream)
                    .labelsHidden()
                    .accessibilityLabel("Instant first frame")
                    .accessibilityHint("Keeps a quiet background capture running near closing time")
                    .help("Keep a quiet background capture running near closing time")
            }
            }
        }
    }
    
    // MARK: - Tilt Triggers Card
    private var tiltCard: some View {
        HCISectionCard(title: "When the Animation Starts", icon: "angle") {
            VStack(spacing: 12) {
                // Start Angle Slider Row
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Starts closing at")
                            .font(.subheadline)

                        InfoButton("Start Angle", content: "Your screen stays normal above this angle. Close past it and the bending begins.")

                        Spacer()

                        Text("\(Int(settings.startTiltAngle))°")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.startTiltAngle, in: 40...120, step: 1)
                        .accessibilityLabel("Starts closing at")
                        .accessibilityValue("\(Int(settings.startTiltAngle)) degrees")
                        .help("Your screen stays normal above this angle")
                }

                Divider()

                // End Angle Slider Row
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fully closed at")
                            .font(.subheadline)

                        InfoButton("Full Fold Angle", content: "The bend finishes and fades to black at this angle.")

                        Spacer()

                        Text("\(Int(settings.endTiltAngle))°")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.endTiltAngle, in: 0...20, step: 1)
                        .accessibilityLabel("Fully closed at")
                        .accessibilityValue("\(Int(settings.endTiltAngle)) degrees")
                        .help("The bend finishes and fades to black at this angle")
                }
            }
        }
    }
    
    // MARK: - Display Source & Menu Bar Card
    private var displaySourceCard: some View {
        HCISectionCard(title: "Display & Menu Bar", icon: "display") {
            VStack(spacing: 12) {
                // Display Source Picker Row
                HStack {
                    Text("Animation shows")
                        .font(.subheadline)

                    InfoButton("Screen Source", content: "Show your real desktop, your wallpaper, included art, or your own photo.")

                    Spacer()

                    Picker("", selection: $settings.imageSourceMode) {
                        ForEach(ImageSourceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                                .help(mode.help)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                    .help("What picture bends when you close the lid")
                }

                Text("“My Open Windows” needs Screen Permission above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(settings.imageSourceMode == .liveCapture ? 1 : 0)

                if settings.imageSourceMode == .customImage {
                    HStack {
                        Text(settings.customImagePath.isEmpty ? "No photo chosen yet" : (settings.customImagePath as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(settings.customImagePath)
                        Spacer()
                        Button("Choose Photo…") {
                            selectCustomImage()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Pick any photo on your Mac to bend")
                    }
                }

                Divider()

                // Menu Bar Toggle Row
                HStack {
                    Text("Lid angle in menu bar")
                        .font(.subheadline)

                    InfoButton("Menu Bar Display", content: "Shows the lid angle next to the macTilt icon.")

                    Spacer()

                    Toggle("", isOn: $settings.showAngleInMenuBar)
                        .labelsHidden()
                        .accessibilityLabel("Lid angle in menu bar")
                        .accessibilityHint("Shows the lid angle next to the macTilt icon")
                        .help("Show the lid angle next to the macTilt icon")
                }
            }
        }
    }
    
    // MARK: - Animation Physics Card
    private var animationPhysicsCard: some View {
        HCISectionCard(title: "How It Feels", icon: "slider.horizontal.3") {
            VStack(spacing: 12) {
                // Feel preset picker
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Feel")
                            .font(.subheadline)

                        InfoButton("Feel", content: "Pick a vibe, then fine-tune below. Each one keeps tracking and anticipation matched so the bend never feels floaty or fake.")

                        Spacer()

                        if settings.feelPreset == .custom {
                            Text("Custom")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(Capsule())
                        }
                    }
                    Picker("", selection: $settings.feelPreset) {
                        Text(FeelPreset.gentle.title).tag(FeelPreset.gentle)
                        Text(FeelPreset.balanced.title).tag(FeelPreset.balanced)
                        Text(FeelPreset.sharp.title).tag(FeelPreset.sharp)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .help("Pick how the bend feels: calm, balanced, or instant")
                    .onChange(of: settings.feelPreset) { _, newValue in
                        isApplyingPreset = true
                        settings.applyFeelPreset(newValue)
                        DispatchQueue.main.async { isApplyingPreset = false }
                    }
                    Text("Pick a vibe, then fine-tune below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Follow Speed
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sticks to your lid")
                            .font(.subheadline)

                        InfoButton("Sticks To Your Lid", content: "How tightly the picture follows your hand. Higher sticks closer; lower trails softly. Tracking and anticipation stay matched automatically.")

                        Spacer()

                        Text("\(Int(settings.followSpeed)) — \(followSuffix)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.followSpeed, in: 6...30, step: 1)
                        .accessibilityLabel("Sticks to your lid")
                        .accessibilityValue("\(Int(settings.followSpeed)), \(followSuffix)")
                        .help("Higher sticks closer to your hand; lower trails softly")
                        .onChange(of: settings.followSpeed) { _, _ in
                            if !isApplyingPreset { settings.feelPreset = .custom }
                        }
                    HStack {
                        Text("Floaty")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Glued")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Blur and Glass Dual Sliders
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Softness while bending")
                                .font(.subheadline)
                            Spacer()
                            Text("\(String(format: "%.1f", settings.blurStrength)) — \(blurSuffix)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.blurStrength, in: 0.2...2.0, step: 0.1)
                            .accessibilityLabel("Softness while bending")
                            .accessibilityValue("\(blurSuffix)")
                            .help("Adds a soft blur mid-bend so motion looks smooth")
                            .onChange(of: settings.blurStrength) { _, _ in
                                if !isApplyingPreset { settings.feelPreset = .custom }
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Shine on the bend")
                                .font(.subheadline)
                            Spacer()
                            Text(shineValueText)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.reflectionIntensity, in: 0.0...2.5, step: 0.1)
                            .accessibilityLabel("Shine on the bend")
                            .accessibilityValue(shineValueText)
                            .help("Adds a light streak across the fold, like glass catching light")
                            .onChange(of: settings.reflectionIntensity) { _, _ in
                                if !isApplyingPreset { settings.feelPreset = .custom }
                            }
                    }
                }
            }
        }
    }

    private var followSuffix: String {
        if settings.followSpeed <= 10 { return "floaty" }
        if settings.followSpeed <= 20 { return "snappy" }
        return "glued"
    }

    private var blurSuffix: String {
        if settings.blurStrength <= 0.3 { return "crisp" }
        if settings.blurStrength <= 0.7 { return "subtle" }
        if settings.blurStrength <= 1.2 { return "dreamy" }
        return "foggy"
    }

    private var shineValueText: String {
        if settings.reflectionIntensity <= 0.05 { return "Off" }
        return String(format: "%.1f — glossy", settings.reflectionIntensity)
    }
    
    // MARK: - Lock Screen & Sleep Wake Card (Optional)
    private var lockScreenCard: some View {
        HCISectionCard(title: "Lock Screen & Waking Up", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show animation on the lock screen")
                            .font(.subheadline)
                        Text("Keeps the bend visible as your Mac wakes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    InfoButton("Lock Screen Wake", content: "macOS hides the lock screen for safety. Tip: in System Settings › Lock Screen, set “Require password” to “After 1 minute” to see the unbend.")

                    Spacer()

                    Toggle("", isOn: $settings.enableLockScreenPriority)
                        .labelsHidden()
                        .accessibilityLabel("Show animation on the lock screen")
                        .accessibilityHint("Keeps the bend visible as your Mac wakes")
                        .help("Keep the animation visible on the lock screen")
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Try the close-and-open movie")
                            .font(.subheadline)
                        Text("Plays the full bend on demand — no need to move your lid.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Play Preview") {
                        LidSensor.shared.triggerPreviewAnimation()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Play the full bend on demand")
                }
            }
        }
    }
    
    // MARK: - Test Preview Card
    private var testPreviewCard: some View {
        HCISectionCard(title: "Try It Now", icon: "play.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Drag to preview")
                        .font(.subheadline)

                    InfoButton("Interactive Preview", content: "Drag the slider to bend your screen without moving the lid.")

                    Spacer()

                    Toggle("", isOn: $settings.isTestModeActive)
                        .labelsHidden()
                        .accessibilityLabel("Drag to preview")
                        .accessibilityHint("Turn on the drag-to-preview slider")
                        .help("Turn on the drag-to-preview slider")
                        .onChange(of: settings.isTestModeActive) { _, newValue in
                            if !newValue {
                                // Immediately clear turn value so the overlay hides at once
                                settings.testTurnValue = 0.0
                            } else {
                                // One fresh frame for the scrub session: the
                                // slider then bends the kept frame without a
                                // screen capture on every tick.
                                OverlayWindowController.shared.captureScreenAsync()
                            }
                        }
                }

                if settings.isTestModeActive {
                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("How far closed")
                                .font(.subheadline)
                            Spacer()
                            Text("\(Int(settings.testTurnValue * 100))% (≈ \(Int(120 - settings.testTurnValue * 85))°)")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.testTurnValue, in: 0.0...1.0) { isEditing in
                            if !isEditing {
                                // Ease back along the same path (a visible
                                // unbend), then stop. Reduced motion: cut
                                // instantly — that is the accessible behavior.
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) {
                                    settings.testTurnValue = 0.0
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.6)) {
                                    if settings.testTurnValue == 0.0 {
                                        settings.isTestModeActive = false
                                        OverlayWindowController.shared.stopOverlay()
                                    }
                                }
                            }
                        }
                        .accessibilityLabel("How far closed")
                        .accessibilityValue("\(Int(settings.testTurnValue * 100)) percent")
                        .help("Drag to bend from open to closed")
                        HStack {
                            Text("Open")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Closed")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
    
    // MARK: - Software Updates Card
    private var softwareUpdateCard: some View {
        HCISectionCard(title: "Software Updates", icon: "arrow.triangle.2.circlepath.circle") {
            VStack(spacing: 12) {
                HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("macTilt \(updater.currentVersion)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .help("Build \(updater.currentBuild)")

                    if updater.isChecking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking for updates…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if updater.updateAvailable {
                        Text("New version available: \(updater.latestVersion)")
                            .font(.caption)
                            .foregroundStyle(Color.green)
                            .fontWeight(.semibold)
                    } else if updater.hasChecked {
                        Text(updater.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("See if a newer macTilt is ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                    
                    Spacer()
                    
                    Button(action: {
                        updater.checkForUpdates(userInitiated: true)
                    }) {
                        HStack(spacing: 4) {
                            if updater.isChecking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Check for Updates")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updater.isChecking)
                }
                
                if updater.updateAvailable {
                    Divider()
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("macTilt \(updater.latestVersion) is ready")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Get the new version from the macTilt website.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Download macTilt \(updater.latestVersion)…") {
                            updater.openLatestRelease()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                
                Divider()
                
                Toggle(isOn: $settings.automaticallyCheckForUpdates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically Check for Updates")
                            .font(.subheadline)
                        Text("Checks when macTilt starts. Nothing runs while you work.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if let lastCheck = updater.lastCheckDate {
                    Text("Last checked \(lastCheck, style: .relative) ago.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
    
    // MARK: - Bottom Footer Bar
    private var footerBar: some View {
        HStack {
            Button("Reset to Defaults") {
                settings.startTiltAngle = 115.0
                settings.endTiltAngle = 3.0
                settings.applyFeelPreset(.balanced)
                settings.imageSourceMode = .liveCapture
                settings.customImagePath = ""
                settings.enableWarmStream = true
                settings.showAngleInMenuBar = true
                settings.isTestModeActive = false
                settings.testTurnValue = 0.0
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Put every slider and switch back the way macTilt arrived")

            Button("Welcome Guide…") {
                MenuBarController.shared.openOnboardingWindow()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Open the welcome guide again")

            Spacer()

            Button("Done") {
                settings.isTestModeActive = false
                settings.testTurnValue = 0.0
                OverlayWindowController.shared.stopOverlay()
                NSApp.keyWindow?.orderOut(nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .help("Close settings")
        }
    }
    
    private func selectCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.customImagePath = url.path
        }
    }
}

// MARK: - Apple HCI Grouped Section Card Component
private struct HCISectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card Title Label
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 2)
            
            // Card Content Container
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(cardBorder, lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Apple HCI Info Popover Button
private struct InfoButton: View {
    let title: String
    let content: String
    @State private var isShowing: Bool = false
    
    init(_ title: String = "", content: String) {
        self.title = title
        self.content = content
    }
    
    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.isEmpty ? "More information" : "More about \(title)")
        .accessibilityHint("Shows an explanation")
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                if !title.isEmpty {
                    Text(title)
                        .font(.headline)
                }
                Text(content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(12)
            .frame(width: 260)
        }
    }
}

