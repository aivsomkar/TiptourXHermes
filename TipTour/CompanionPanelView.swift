//
//  CompanionPanelView.swift
//  TipTour
//
//  SwiftUI content hosted inside the menu bar panel. Minimal layout:
//  status header, permissions setup or hotkey hint, neko toggle,
//  developer section, footer. Dark aesthetic via DS.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            arcReactorSection
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if !companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                permissionsListSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                startButton
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer().frame(height: 14)
                    .padding(.horizontal, 16)

                Spacer().frame(height: 4)
                nekoModeToggleRow
                    .padding(.horizontal, 16)
            }

            Spacer().frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 520)
        .background(panelBackground)
        .sheet(isPresented: $showSettings) {
            SettingsSheetView(isPresented: $showSettings)
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        VStack(spacing: 0) {
            // Top status bar
            HStack(spacing: 10) {
                StatusPulseDot(color: statusDotColor)
                Text("TIPTOUR // VOICE OS")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundColor(DS.Colors.jarvisAccent)

                Spacer()

                Text(">  \(statusText.uppercased())")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(statusDotColor)
                    .opacity(0.85)

                pinToggleButton

                Button(action: {
                    NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Tech baseline under the header
            Rectangle()
                .fill(DS.Colors.jarvisBorder)
                .frame(height: 1)
                .padding(.horizontal, 4)
        }
    }

    /// Central Arc Reactor + 4-up status grid. The dashboard's visual
    /// centerpiece — driven by voiceState (color) and the live mic-power
    /// level (pulse intensity).
    private var arcReactorSection: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                // Left side: status grid
                VStack(alignment: .leading, spacing: 8) {
                    statusGridRow(label: "MIC", granted: companionManager.hasMicrophonePermission)
                    statusGridRow(label: "SCREEN", granted: companionManager.hasScreenRecordingPermission)
                    statusGridRow(label: "A11Y", granted: companionManager.hasAccessibilityPermission)
                    statusGridRow(label: "CONTENT", granted: companionManager.hasScreenContentPermission)
                }
                .frame(width: 130, alignment: .leading)

                Spacer()

                // Centerpiece
                ArcReactorView(
                    pulseIntensity: companionManager.currentAudioPowerLevel,
                    stateColor: arcReactorColor
                )

                Spacer()

                // Right side: clock + provider info
                VStack(alignment: .trailing, spacing: 8) {
                    LiveClockView()
                    if let provider = HermesSetupCoordinator().configuredProvider {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("PROVIDER")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .tracking(1.2)
                                .foregroundColor(DS.Colors.textTertiary)
                            Text(provider.displayName.uppercased())
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(1.0)
                                .foregroundColor(DS.Colors.jarvisAccent)
                        }
                    }
                }
                .frame(width: 130, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
    }

    /// Returns the cyan tint for the Arc Reactor based on voice state.
    private var arcReactorColor: Color {
        switch companionManager.voiceState {
        case .idle:       return DS.Colors.jarvisAccentDim
        case .listening:  return DS.Colors.jarvisAccent
        case .responding: return DS.Colors.cyan300
        case .processing: return DS.Colors.warning
        }
    }

    /// One row of the status grid: a small filled dot + monospaced label.
    private func statusGridRow(label: String, granted: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? DS.Colors.jarvisAccent : DS.Colors.textTertiary)
                .frame(width: 6, height: 6)
                .shadow(color: granted ? DS.Colors.jarvisAccent.opacity(0.6) : .clear, radius: 3)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundColor(granted ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            Spacer()
        }
    }

    /// Pushpin toggle. When on, the panel stays visible regardless of
    /// outside clicks. When off (default), the panel behaves like a
    /// standard menu bar popover.
    private var pinToggleButton: some View {
        Button(action: {
            companionManager.setPanelPinned(!companionManager.isPanelPinned)
        }) {
            Image(systemName: companionManager.isPanelPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(
                    companionManager.isPanelPinned
                        ? DS.Colors.accent
                        : DS.Colors.textTertiary
                )
                .rotationEffect(.degrees(companionManager.isPanelPinned ? 0 : 45))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(
                            companionManager.isPanelPinned
                                ? DS.Colors.accent.opacity(0.15)
                                : Color.white.opacity(0.08)
                        )
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(companionManager.isPanelPinned
            ? "Unpin: panel will close when you click outside"
            : "Pin: panel will stay open when you click outside")
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control + Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet TipTour.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant the four below to keep using TipTour.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm TipTour.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Hold Control+Option, ask anything about what's on your screen, and I'll point right at it.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Grant the permissions below to get started.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Permissions List

    private var permissionsListSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow
            accessibilityPermissionRow
            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

            if !companionManager.allPermissionsGranted {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, 1)
                    Text("Everything stays on your Mac. Screenshots and audio are only sent to Gemini when you hold ⌃⌥ to talk.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("So I can move the cursor and read what's on screen.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                HStack(spacing: 6) {
                    grantButton {
                        WindowPositionManager.requestAccessibilityPermission()
                    }
                    Button(action: {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(isGranted
                         ? "So I can see your screen when you ask for help."
                         : "Quit and reopen after granting.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    WindowPositionManager.requestScreenRecordingPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Content")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Lets me read the screen continuously without picking a window each time.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    companionManager.requestScreenContentPermission()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("So you can hold ⌃⌥ and talk to me.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isGranted {
                grantedPill
            } else {
                grantButton {
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var grantedPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DS.Colors.success)
                .frame(width: 6, height: 6)
            Text("Granted")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.success)
        }
    }

    private func grantButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Grant")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Neko Mode Toggle

    /// Whimsical toggle that swaps the blue triangle cursor for a
    /// pixel-art cat (classic oneko sprites).
    private var nekoModeToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cat.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        companionManager.isNekoModeEnabled
                            ? DS.Colors.accent
                            : DS.Colors.textTertiary
                    )
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Neko mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("replace cursor with a pixel cat")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isNekoModeEnabled },
                set: { companionManager.setNekoModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var feedbackButton: some View {
        Button(action: {
            if let url = URL(string: "https://x.com/milindlabs") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10))
                Text("Feedback")
                    .font(.system(size: 11))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var footerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                feedbackButton

                footerButton("Settings", systemImage: "gearshape", toggled: showSettings) {
                    showSettings = true
                }

                // Always-visible Dev button — gives shipped users access to
                // the voice-backend picker and BYOK key inputs. The truly
                // debug-only rows (Detection Overlay, Test Cursor Flight,
                // Reset All) stay #if DEBUG-gated inside the section.
                footerButton("Dev", systemImage: "wrench", toggled: showDevTools) {
                    showDevTools.toggle()
                }

                Spacer()

                footerButton("Quit", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }

            if showDevTools {
                devToolsSection
                    .padding(.top, 8)
            }
        }
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        toggled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundColor(toggled ? DS.Colors.textSecondary : DS.Colors.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Dev Tools

    /// Internal-only debug controls. Shipping provider/key management and
    /// Hermes runtime-version display now live in Settings → Models; the
    /// rows here are gated behind `#if DEBUG` because they have no use to
    /// a casual user.
    @State private var showDevTools: Bool = false
    @State private var showSettings: Bool = false

    private var devToolsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if DEBUG
            sectionHeader("DEBUG")

            devToolRow("Test Cursor Flight", systemImage: "arrow.up.right") {
                let s = NSScreen.main!
                companionManager.detectedElementScreenLocation = CGPoint(x: s.frame.midX, y: s.frame.midY)
                companionManager.detectedElementDisplayFrame = s.frame
                companionManager.detectedElementBubbleText = "Test"
                NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
            }

            Spacer().frame(height: 6)
            #endif
        }
        .padding(.vertical, 4)
    }

    /// Compact uppercase section label used inside the Dev panel.
    /// JARVIS-style: monospaced, cyan-tinted, with a subtle leading marker.
    private func sectionHeader(_ text: String) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(DS.Colors.jarvisAccent)
                .frame(width: 6, height: 1)
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundColor(DS.Colors.jarvisAccent)
            Rectangle()
                .fill(DS.Colors.jarvisAccent.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func devToolRow(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundColor(destructive ? .red.opacity(0.7) : DS.Colors.textTertiary)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(destructive ? .red.opacity(0.7) : DS.Colors.textSecondary)

                Spacer()

                trailing()
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(DevToolRowButtonStyle())
        .pointerCursor()
    }

    private struct DevToolRowButtonStyle: ButtonStyle {
        @State private var isHovered = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isPressed
                              ? DS.Colors.surface4
                              : isHovered ? DS.Colors.surface3 : Color.clear)
                )
                .onHover { isHovered = $0 }
        }
    }

    // MARK: - Visuals

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.background)

            // Very subtle horizontal scan-line pattern — 1px lines every
            // 3px at low opacity. Just enough to give the surface a "CRT"
            // texture without being distracting.
            scanLineOverlay
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.Colors.jarvisBorder, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
        .shadow(color: DS.Colors.jarvisGlow, radius: 24, x: 0, y: 0)
    }

    private var scanLineOverlay: some View {
        Canvas { ctx, size in
            let lineSpacing: CGFloat = 3
            let lineColor = DS.Colors.jarvisAccent.opacity(0.04)
            var y: CGFloat = 0
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                ctx.fill(Path(rect), with: .color(lineColor))
                y += lineSpacing
            }
        }
        .allowsHitTesting(false)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }
}

/// Animated status dot with concentric pulse rings. The inner dot fades
/// up the outer ring while the outer ring expands and fades out — gives
/// the "live signal" look without distracting motion.
fileprivate struct StatusPulseDot: View {
    let color: Color
    @State private var animationOn = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 1)
                .frame(width: 16, height: 16)
                .scaleEffect(animationOn ? 1.4 : 1.0)
                .opacity(animationOn ? 0.0 : 0.6)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                animationOn = true
            }
        }
    }
}

/// Animated Arc Reactor centerpiece for the JARVIS dashboard. Renders
/// concentric cyan rings with a slow rotating tick-marked outer ring,
/// a static glowing inner core, and a subtle breathing pulse driven by
/// `pulseIntensity` (0.0 = idle, 1.0 = peak mic activity).
fileprivate struct ArcReactorView: View {
    /// 0.0 — 1.0 — drives the outer-ring brightness + glow radius.
    /// Wire this to mic power level for live reactivity.
    let pulseIntensity: CGFloat

    /// State color: cyan when active, dim when idle, red on error.
    let stateColor: Color

    @State private var rotation: Double = 0
    @State private var breathing: Bool = false

    var body: some View {
        ZStack {
            // Outermost: thin rotating ring with tick marks
            outerTickRing
                .rotationEffect(.degrees(rotation))

            // Middle: thicker cyan stroke
            Circle()
                .strokeBorder(stateColor.opacity(0.5), lineWidth: 2)
                .frame(width: 110, height: 110)

            // Inner: filled glowing core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [stateColor.opacity(0.9), stateColor.opacity(0.2)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 35
                    )
                )
                .frame(width: 60, height: 60)
                .shadow(color: stateColor.opacity(0.7), radius: 12)
                .scaleEffect(breathing ? 1.08 : 0.96)

            // Hottest center dot
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .shadow(color: stateColor, radius: 6)
        }
        .frame(width: 160, height: 160)
        .shadow(color: stateColor.opacity(0.2 + 0.3 * pulseIntensity), radius: 30)
        .onAppear {
            withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    /// 32 short cyan tick marks around a thin ring, drawn with TimelineView
    /// for static performance.
    private var outerTickRing: some View {
        ZStack {
            Circle()
                .strokeBorder(stateColor.opacity(0.4), lineWidth: 1)
                .frame(width: 150, height: 150)
            ForEach(0..<32, id: \.self) { i in
                Rectangle()
                    .fill(stateColor.opacity(i % 4 == 0 ? 0.9 : 0.45))
                    .frame(width: 1, height: i % 4 == 0 ? 8 : 4)
                    .offset(y: -75)
                    .rotationEffect(.degrees(Double(i) * 360.0 / 32.0))
            }
        }
        .frame(width: 160, height: 160)
    }
}

/// Right-aligned live clock — refreshes every second via TimelineView.
fileprivate struct LiveClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeString(context.date))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(DS.Colors.jarvisAccent)
                Text(timeZoneString())
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    private func timeZoneString() -> String {
        let abbreviation = TimeZone.current.abbreviation() ?? "UTC"
        return abbreviation.uppercased()
    }
}
