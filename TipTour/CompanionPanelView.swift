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
        .frame(width: 320)
        .background(panelBackground)
        .sheet(isPresented: $showFirstRunSetup) {
            FirstRunSetupView(
                isPresented: $showFirstRunSetup,
                onSetupComplete: {
                    // Toggle to force the body to recompute setupCoordinator
                    // and re-evaluate needsSetup.
                    setupNeedsRefresh.toggle()
                }
            )
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("TipTour")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            pinToggleButton

            Button(action: {
                NotificationCenter.default.post(name: .tipTourDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
                if setupCoordinator.needsSetup {
                    footerButton("Set up Hermes", systemImage: "key", toggled: false) {
                        showFirstRunSetup = true
                    }
                }

                feedbackButton

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

    /// Always-visible. Shipping users get the voice-backend picker and
    /// bring-your-own-key fields here so they can switch models or wire
    /// in their own OpenAI / Gemini key without rebuilding from source.
    /// The detection-overlay / cursor-flight / reset-all rows below are
    /// still gated by `#if DEBUG` because they're internal-only and
    /// have no use to a casual user.
    @State private var showDevTools: Bool = false
    @State private var devGeminiKeyInput: String = ""
    @State private var devGeminiKeyStatus: String = ""
    @State private var devAnthropicKeyInput: String = ""
    @State private var devAnthropicKeyStatus: String = ""
    @State private var devOpenAIKeyInput: String = ""
    @State private var devOpenAIKeyStatus: String = ""
    @State private var devLumaKeyInput: String = ""
    @State private var devLumaKeyStatus: String = ""

    @State private var showFirstRunSetup: Bool = false
    @State private var setupNeedsRefresh: Bool = false
    // Re-evaluate every body call so the button hides as soon as the user
    // finishes setup. The coordinator is cheap to construct (no I/O until
    // methods are called).
    private var setupCoordinator: HermesSetupCoordinator {
        _ = setupNeedsRefresh   // touch to force a recompute
        return HermesSetupCoordinator()
    }

    /// One-line bring-your-own-key row. Icon + label on the left, a
    /// SecureField that grows to fill, and a single trailing icon button
    /// that toggles between Save (when there's input) and Clear (when a
    /// key is already saved). Status flashes briefly after either action.
    private func byokKeyRow(
        title: String,
        placeholder: String,
        input: Binding<String>,
        save: @escaping () -> Void,
        clear: @escaping () -> Void,
        status: Binding<String>,
        hasSavedKey: Bool
    ) -> some View {
        let trimmedInput = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let saveDisabled = trimmedInput.isEmpty
        return HStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 10))
                .foregroundColor(hasSavedKey ? DS.Colors.accent : DS.Colors.textTertiary)
                .frame(width: 16)

            Text(title)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 70, alignment: .leading)

            SecureField(placeholder, text: input)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )

            Button {
                save()
                status.wrappedValue = "Saved"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if status.wrappedValue == "Saved" { status.wrappedValue = "" }
                }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(saveDisabled ? DS.Colors.textTertiary : .white)
                    .frame(width: 22, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(saveDisabled ? Color.white.opacity(0.06) : DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(saveDisabled)
            .pointerCursor()
            .help("Save")

            Button {
                clear()
                status.wrappedValue = "Cleared"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if status.wrappedValue == "Cleared" { status.wrappedValue = "" }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Clear")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

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

            sectionHeader("API KEYS (optional)")

            byokKeyRow(
                title: "Gemini",
                placeholder: "AIzaSy…",
                input: $devGeminiKeyInput,
                save: {
                    KeychainStore.geminiAPIKey = devGeminiKeyInput
                },
                clear: {
                    devGeminiKeyInput = ""
                    KeychainStore.geminiAPIKey = nil
                },
                status: $devGeminiKeyStatus,
                hasSavedKey: !(KeychainStore.geminiAPIKey ?? "").isEmpty
            )

            // Save/clear status text — auto-clears after a beat.
            if !devGeminiKeyStatus.isEmpty {
                Text(devGeminiKeyStatus)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            byokKeyRow(
                title: "Anthropic",
                placeholder: "sk-ant-…",
                input: $devAnthropicKeyInput,
                save: { KeychainStore.anthropicAPIKey = devAnthropicKeyInput },
                clear: { devAnthropicKeyInput = ""; KeychainStore.anthropicAPIKey = nil },
                status: $devAnthropicKeyStatus,
                hasSavedKey: !(KeychainStore.anthropicAPIKey ?? "").isEmpty
            )
            if !devAnthropicKeyStatus.isEmpty {
                Text(devAnthropicKeyStatus)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            byokKeyRow(
                title: "OpenAI",
                placeholder: "sk-…",
                input: $devOpenAIKeyInput,
                save: { KeychainStore.openAIAPIKey = devOpenAIKeyInput },
                clear: { devOpenAIKeyInput = ""; KeychainStore.openAIAPIKey = nil },
                status: $devOpenAIKeyStatus,
                hasSavedKey: !(KeychainStore.openAIAPIKey ?? "").isEmpty
            )
            if !devOpenAIKeyStatus.isEmpty {
                Text(devOpenAIKeyStatus)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            byokKeyRow(
                title: "Luma",
                placeholder: "luma-…",
                input: $devLumaKeyInput,
                save: { KeychainStore.lumaAPIKey = devLumaKeyInput },
                clear: { devLumaKeyInput = ""; KeychainStore.lumaAPIKey = nil },
                status: $devLumaKeyStatus,
                hasSavedKey: !(KeychainStore.lumaAPIKey ?? "").isEmpty
            )
            if !devLumaKeyStatus.isEmpty {
                Text(devLumaKeyStatus)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }

            // Hermes runtime version — sourced from the bundled
            // `hermes-version.txt` baked in at build time. Rendered as a
            // single dim monospaced line so it reads like a build stamp.
            if let hermesVersionFileURL = HermesRuntimeVersion.bundledURL,
               let hermesRuntimeVersion = try? HermesRuntimeVersion.read(from: hermesVersionFileURL) {
                HStack {
                    Text(hermesRuntimeVersion.shortDisplayString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }
        }
        .onAppear {
            // Pre-populate the field from Keychain so the user can see
            // whether a key is already saved (revealed as dots in the
            // SecureField).
            devGeminiKeyInput = KeychainStore.geminiAPIKey ?? ""
            devAnthropicKeyInput = KeychainStore.anthropicAPIKey ?? ""
            devOpenAIKeyInput = KeychainStore.openAIAPIKey ?? ""
            devLumaKeyInput = KeychainStore.lumaAPIKey ?? ""
        }
        .padding(.vertical, 4)
    }

    /// Compact uppercase section label used inside the Dev panel.
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.4)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 3)
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
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
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
