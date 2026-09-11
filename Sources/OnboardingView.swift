import SwiftUI
import AppKit

public struct OnboardingView: View {
    @ObservedObject var settings: AppSettings = AppSettings.shared
    public var onDismiss: (() -> Void)?
    
    public init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                appIconView
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                
                VStack(spacing: 4) {
                    Text("Welcome to macTilt")
                        .font(.system(size: 26, weight: .bold))

                    Text("Watch your screen bend like paper as you close your MacBook.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 32)
            .padding(.horizontal, 28)
            
            // Feature Highlights
            VStack(spacing: 16) {
                FeatureRow(
                    icon: "laptopcomputer",
                    iconColor: .blue,
                    title: "Follows your hands",
                    subtitle: "The picture bends exactly with your lid — open, halfway, closed."
                )

                FeatureRow(
                    icon: "battery.100.bolt",
                    iconColor: .green,
                    title: "Sips no battery",
                    subtitle: "Does nothing while you work. Wakes only as you close the lid."
                )

                FeatureRow(
                    icon: "record.circle.fill",
                    iconColor: .orange,
                    title: "Screen Recording Permission",
                    subtitle: "Takes one picture of your desktop to bend it. Never leaves this Mac."
                )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            
            // Permission Action Card
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(settings.hasScreenRecordingPermission ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    
                    Text(settings.hasScreenRecordingPermission ? "Screen Recording Permission Active" : "Screen Recording Permission Required")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    if !settings.hasScreenRecordingPermission {
                        Button(action: {
                            ScreenCapture.shared.requestPermission()
                            ScreenCapture.shared.openSettings()
                        }) {
                            Text("Allow in System Settings…")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                if !settings.hasScreenRecordingPermission {
                    HStack {
                        Text("After you switch it on in System Settings, quit and reopen macTilt.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Button(action: {
                            ScreenCapture.shared.relaunchApp()
                        }) {
                            Label("Quit and Reopen", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .padding(.horizontal, 28)
            
            Spacer()
            
            // Bottom Action
            HStack {
                Spacer()
                Button(action: {
                    settings.hasCompletedOnboarding = true
                    onDismiss?()
                }) {
                    Text("Get Started")
                        .font(.headline)
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Spacer()
            }
            .padding(.bottom, 28)
            .padding(.top, 12)
        }
        .frame(width: 520, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    @ViewBuilder
    private var appIconView: some View {
        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: iconUrl) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
        } else if let appIcon = NSApplication.shared.applicationIconImage {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "laptopcomputer")
                .resizable()
                .scaledToFit()
                .foregroundColor(.accentColor)
                .padding(16)
                .background(Color.blue.opacity(0.1))
        }
    }
}

// MARK: - Apple HCI Feature Row
private struct FeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            
            Spacer(minLength: 0)
        }
    }
}
