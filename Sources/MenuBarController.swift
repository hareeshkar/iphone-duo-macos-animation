import Foundation
import AppKit
import SwiftUI

public final class MenuBarController: NSObject, NSWindowDelegate {
    public static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem?
    private var controlPanelWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var angleMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var testToggleItem: NSMenuItem?
    private var lastAngle: Double = 120.0
    private var lastIsConnected: Bool = false
    
    public override init() {
        super.init()
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "macTilt")
            button.imagePosition = .imageLeading
            button.title = ""
        }
        
        let menu = NSMenu()
        
        let header = NSMenuItem(title: "macTilt", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let updateItem = NSMenuItem(title: "Download macTilt Update…", action: #selector(openLatestRelease), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        self.updateMenuItem = updateItem
        menu.addItem(updateItem)

        let angleItem = NSMenuItem(title: "Lid: opening…", action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        self.angleMenuItem = angleItem
        menu.addItem(angleItem)

        menu.addItem(NSMenuItem.separator())

        let openSettings = NSMenuItem(title: "macTilt Settings…", action: #selector(openControlPanel), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)

        let welcomeItem = NSMenuItem(title: "Welcome Guide…", action: #selector(openOnboardingWindow), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        let previewItem = NSMenuItem(title: "Play Close-and-Open Preview", action: #selector(triggerFoldPreview), keyEquivalent: "p")
        previewItem.target = self
        menu.addItem(previewItem)

        let testToggle = NSMenuItem(title: "Show Preview Slider", action: #selector(toggleTestMode), keyEquivalent: "t")
        testToggle.target = self
        self.testToggleItem = testToggle
        menu.addItem(testToggle)

        let captureItem = NSMenuItem(title: "Take a Fresh Screen Picture", action: #selector(recaptureScreen), keyEquivalent: "r")
        captureItem.target = self
        menu.addItem(captureItem)
        
        let checkUpdateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit macTilt", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
        self.statusItem = item
        
        refreshMenuBarTitle()
    }
    
    public func updateAngleDisplay(angle: Double, isConnected: Bool) {
        lastAngle = angle
        lastIsConnected = isConnected

        if let button = statusItem?.button {
            if AppSettings.shared.showAngleInMenuBar {
                if AppSettings.shared.isHardwareSensor {
                    button.title = " \(Int(angle))°"
                } else {
                    button.title = ""
                }
            } else {
                button.title = ""
            }
            button.setAccessibilityLabel("macTilt, lid at \(Int(angle)) degrees")
        }

        if let angleItem = self.angleMenuItem {
            if isConnected {
                if AppSettings.shared.isHardwareSensor {
                    let status = AppSettings.shared.isClosing ? "closing" : "open"
                    angleItem.title = "Lid: \(Int(angle))° — \(status)"
                } else {
                    angleItem.title = "Lid: automatic animation"
                }
            } else {
                angleItem.title = "Lid sensor off"
            }
        }
    }
    
    public func refreshMenuBarTitle() {
        if let button = statusItem?.button {
            if AppSettings.shared.showAngleInMenuBar {
                button.title = " \(Int(lastAngle))°"
            } else {
                button.title = ""
            }
        }
    }
    
    @objc public func openControlPanel() {
        if let existing = controlPanelWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.center()
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.contentViewController = NSHostingController(rootView: LiquidGlassControlPanel())
        win.isReleasedWhenClosed = false
        
        self.controlPanelWindow = win
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc public func openOnboardingWindow() {
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.center()
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        
        let onboardingView = OnboardingView { [weak self, weak win] in
            win?.close()
            self?.openControlPanel()
        }
        
        win.contentViewController = NSHostingController(rootView: onboardingView)
        win.isReleasedWhenClosed = false
        
        self.onboardingWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - NSWindowDelegate
    
    public func windowWillClose(_ notification: Notification) {
        // When the control panel is dismissed, always clear test mode so the
        // fold overlay doesn't stay frozen on screen. Belt-and-braces with
        // SwiftUI onDisappear below: either path fully hides the overlay.
        if AppSettings.shared.isTestModeActive {
            AppSettings.shared.isTestModeActive = false
            AppSettings.shared.testTurnValue = 0.0
        }
        OverlayWindowController.shared.stopOverlay()
    }
    
    @objc private func triggerFoldPreview() {
        LidSensor.shared.triggerPreviewAnimation()
    }
    
    @objc private func toggleTestMode() {
        let current = AppSettings.shared.isTestModeActive
        AppSettings.shared.isTestModeActive = !current
        if !current {
            AppSettings.shared.testTurnValue = 0.5
            // Same one-frame priming the in-panel toggle performs: without
            // it the first scrub renders stale-or-nothing until a fetch lands.
            OverlayWindowController.shared.captureScreenAsync()
        } else {
            AppSettings.shared.testTurnValue = 0.0
        }
        testToggleItem?.title = current ? "Show Preview Slider" : "Hide Preview Slider"
    }
    
    @objc @MainActor private func recaptureScreen() {
        OverlayWindowController.shared.captureScreenAsync()
    }
    
    public func refreshUpdateMenuState() {
        DispatchQueue.main.async {
            if UpdateChecker.shared.updateAvailable {
                self.updateMenuItem?.title = "Download macTilt \(UpdateChecker.shared.latestVersion)…"
                self.updateMenuItem?.isHidden = false
            } else {
                self.updateMenuItem?.isHidden = true
            }
        }
    }
    
    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates(userInitiated: true)
    }
    
    @objc private func openLatestRelease() {
        UpdateChecker.shared.openLatestRelease()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
