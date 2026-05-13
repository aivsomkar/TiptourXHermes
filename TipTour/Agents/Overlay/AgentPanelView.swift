// TipTour/Agents/Overlay/AgentPanelView.swift

import SwiftUI

// MARK: - Color palette

/// Five-slot tint palette for agent reactors. Cycles when there are more than 5 agents.
/// Intentionally module-level so AgentOverlayStackView can import it without
/// coupling to a specific view type.
let agentReactorColorPalette: [Color] = [
    Color(red: 0,     green: 0.831, blue: 0.753), // teal   — matches main Arc Reactor cursor
    Color(red: 0.545, green: 0.361, blue: 0.965), // violet
    Color(red: 0.957, green: 0.620, blue: 0.043), // amber
    Color(red: 0.957, green: 0.247, blue: 0.369), // rose
    Color(red: 0.063, green: 0.725, blue: 0.506), // emerald
]

// MARK: - AgentReactorButton

/// One background agent represented as a row: Arc Reactor SVG on the left,
/// agent name on the right. Uses the same frameProgress crossfade technique
/// as ArcReactorCursorView — active/busy agents run the full wave sweep
/// (frames 1→5→1), completed agents hold Frame 5, errored agents freeze at
/// Frame 1 with a red badge and play a shake animation.
struct AgentReactorButton: View {
    let status: AgentStatus
    let agentColor: Color
    let isSelected: Bool
    let onTap: () -> Void

    private let displaySize: CGFloat = 32
    private let waveTickInterval: Double = 0.13

    @State private var frameProgress: Double = 1.0
    @State private var waveStepIndex: Int = 0
    @State private var errorShakeOffset: CGFloat = 0
    /// Drives the pulsing halo around active/busy reactors. Toggled by
    /// `applyStateTransition`; loops 0.0 ↔ 1.0 forever while in
    /// `.active` / `.busy`, freezes at 0.0 in every other state.
    @State private var activeHaloPhase: Double = 0.0

    private static let wavePattern: [Int] = [1, 2, 3, 4, 5, 4, 3, 2]

    private var isWaveActive: Bool {
        status.state == .active || status.state == .busy
    }

    private var isCompleted: Bool {
        status.state == .completed
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                TimelineView(.animation(minimumInterval: waveTickInterval, paused: !isWaveActive)) { context in
                    reactorImageView
                        .onChange(of: context.date) { _, _ in advanceWaveTick() }
                }
                .frame(width: displaySize, height: displaySize)
                // Bottom-most: pulsing halo (only visible when active)
                .background { activeHalo }
                .overlay(alignment: .topTrailing) { stateBadge }
                .overlay { selectionRing }

                VStack(alignment: .leading, spacing: 1) {
                    Text(status.agentName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(agentColor.opacity(0.9))
                        .lineLimit(1)
                    // Sub-label: the current step (when active) or the
                    // canonical state label (when done / errored). Lets
                    // the user tell at a glance "still searching..." vs
                    // "Done" without expanding the card.
                    Text(secondaryLabelText)
                        .font(.system(size: 9))
                        .foregroundColor(secondaryLabelColor)
                        .lineLimit(1)
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .offset(x: errorShakeOffset)
        .onAppear { applyStateTransition(status.state) }
        .onChange(of: status.state) { _, newState in
            applyStateTransition(newState)
            if case .error = newState { playErrorShake() }
        }
    }

    /// Soft pulsing halo behind the reactor, ONLY visible when the
    /// agent is active or busy. Makes the active state unmistakable
    /// without depending on the user noticing the reactor frame sweep.
    /// Phase animates 0 ↔ 1 on a 1.0s ease-in-out loop while active.
    @ViewBuilder
    private var activeHalo: some View {
        if isWaveActive {
            Circle()
                .fill(agentColor.opacity(0.35))
                .frame(width: displaySize + 14, height: displaySize + 14)
                .scaleEffect(0.85 + 0.25 * activeHaloPhase)
                .opacity(0.45 + 0.55 * (1.0 - activeHaloPhase))
                .blur(radius: 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        activeHaloPhase = 1.0
                    }
                }
                .onDisappear {
                    activeHaloPhase = 0.0
                }
        }
    }

    private var secondaryLabelText: String {
        switch status.state {
        case .active, .busy:
            // Trim the per-step description to keep the row narrow.
            let trimmed = status.currentStep
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Working…" : trimmed
        case .blocked:
            return "Needs input"
        case .completed:
            return "Done · \(status.stepHistory.count) step\(status.stepHistory.count == 1 ? "" : "s")"
        case .error(let message):
            return "Error: \(message)"
        case .terminated:
            return "Stopped"
        case .idle:
            return "Idle"
        case .spawning:
            return "Starting…"
        }
    }

    private var secondaryLabelColor: Color {
        switch status.state {
        case .active, .busy:    return DS.Colors.textTertiary
        case .blocked:          return DS.Colors.warning
        case .error:            return DS.Colors.destructive
        case .completed:        return DS.Colors.success
        default:                return DS.Colors.textTertiary
        }
    }

    // MARK: - Reactor image composite

    @ViewBuilder
    private var reactorImageView: some View {
        ZStack {
            ForEach(1...5, id: \.self) { frameIndex in
                Image("ReactorFrame\(frameIndex)")
                    .resizable()
                    .scaledToFit()
                    .opacity(opacityForFrame(frameIndex))
            }
        }
        .mask(
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.85),
                    .init(color: .clear,  location: 1.0)
                ]),
                center: .center,
                startRadius: 0,
                endRadius: displaySize / 2
            )
        )
    }

    /// State-specific corner badge. Replaces the previous error-only
    /// badge with a per-state indicator: red exclamation for errors,
    /// green checkmark for completed, amber pause for blocked.
    /// `.active` / `.busy` have no badge — they're communicated by the
    /// pulsing halo behind the reactor.
    @ViewBuilder
    private var stateBadge: some View {
        switch status.state {
        case .error:
            badge(fill: Color.red, symbol: "exclamationmark")
        case .completed:
            badge(fill: DS.Colors.success, symbol: "checkmark")
        case .blocked:
            badge(fill: DS.Colors.warning, symbol: "pause.fill")
        case .terminated:
            badge(fill: DS.Colors.textTertiary, symbol: "xmark")
        default:
            EmptyView()
        }
    }

    /// Reusable 10×10 corner badge — colored disc + tiny SF Symbol.
    private func badge(fill: Color, symbol: String) -> some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                )
            Image(systemName: symbol)
                .font(.system(size: 6, weight: .bold))
                .foregroundColor(.white)
        }
        .offset(x: 3, y: -3)
    }

    @ViewBuilder
    private var selectionRing: some View {
        if isSelected {
            Circle()
                .stroke(ArcReactorColors.arcTeal, lineWidth: 2)
                .frame(width: displaySize + 6, height: displaySize + 6)
        }
    }

    // MARK: - Animation helpers

    private func opacityForFrame(_ index: Int) -> Double {
        max(0.0, 1.0 - abs(frameProgress - Double(index)))
    }

    private func applyStateTransition(_ newState: AgentState) {
        switch newState {
        case .spawning:
            withAnimation(.easeInOut(duration: 0.5)) { frameProgress = 1.0 }
        case .active, .busy:
            break // driven continuously by advanceWaveTick
        case .idle:
            withAnimation(.easeInOut(duration: 0.5)) { frameProgress = 2.0 }
        case .blocked:
            withAnimation(.easeInOut(duration: 0.5)) { frameProgress = 3.0 }
        case .completed:
            withAnimation(.easeInOut(duration: 0.8)) { frameProgress = 5.0 }
        case .error, .terminated:
            withAnimation(.easeInOut(duration: 0.3)) { frameProgress = 1.0 }
        }
    }

    private func advanceWaveTick() {
        guard isWaveActive else { return }
        waveStepIndex = (waveStepIndex + 1) % Self.wavePattern.count
        let target = Double(Self.wavePattern[waveStepIndex])
        withAnimation(.easeInOut(duration: 0.09)) { frameProgress = target }
    }

    /// Four-beat horizontal shake that plays when the agent transitions to .error.
    private func playErrorShake() {
        let distance: CGFloat = 5
        let beat: Double = 0.06
        withAnimation(.linear(duration: beat)) { errorShakeOffset = distance }
        DispatchQueue.main.asyncAfter(deadline: .now() + beat * 1) {
            withAnimation(.linear(duration: beat)) { errorShakeOffset = -distance }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + beat * 2) {
            withAnimation(.linear(duration: beat)) { errorShakeOffset = distance }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + beat * 3) {
            withAnimation(.spring(response: 0.2)) { errorShakeOffset = 0 }
        }
    }
}

// MARK: - AgentDetailCard

/// Expanded detail panel shown below the reactor row when the user taps an agent.
/// Displays: header with name + state, scrollable step history (including the
/// current in-progress step), a metrics strip, and an interrupt text field.
struct AgentDetailCard: View {
    let status: AgentStatus
    let agentColor: Color
    let onDismiss: () -> Void
    let onSendInterrupt: (String) -> Void

    @State private var interruptText: String = ""

    private var currentBlocker: AgentBlocker? {
        if case .blocked(let blocker) = status.state { return blocker }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider().background(DS.Colors.borderSubtle)
            stepHistorySection
            Divider().background(DS.Colors.borderSubtle)
            metricsRow
            Divider().background(DS.Colors.borderSubtle)
            interruptSection
        }
        .background(DS.Colors.surface1)
        .cornerRadius(DS.CornerRadius.large)
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .stroke(agentColor.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.agentName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(status.state.displayLabel)
                    .font(.system(size: 10))
                    .foregroundColor(agentColor)
            }

            Spacer()

            Text("\(status.tokensUsed.formatted()) tok")
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Steps

    private var stepHistorySection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if status.stepHistory.isEmpty && status.currentStep.isEmpty && currentBlocker == nil {
                        Text("Waiting to start…")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }

                    ForEach(status.stepHistory.indices, id: \.self) { index in
                        stepRow(step: status.stepHistory[index])
                            .id(index)
                    }

                    // In-progress step with a spinner
                    if !status.currentStep.isEmpty,
                       status.state == .busy || status.state == .active {
                        HStack(alignment: .top, spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 12, height: 12)
                            Text(status.currentStep)
                                .font(isToolStep(status.currentStep)
                                      ? .system(size: 11, design: .monospaced)
                                      : .system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .id("in-progress")
                    }

                    // Blocker message
                    if let blocker = currentBlocker {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.warning)
                            Text(blocker.description)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            // Auto-scroll to the bottom whenever a new step lands so
            // the user sees the latest action instead of having to
            // scroll down manually every time a tool result arrives.
            .onChange(of: status.stepHistory.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if !status.currentStep.isEmpty {
                        proxy.scrollTo("in-progress", anchor: .bottom)
                    } else if !status.stepHistory.isEmpty {
                        proxy.scrollTo(status.stepHistory.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// One step row. Tool invocations and their results render in
    /// monospaced font so the agent's transcript is easy to scan as a
    /// timeline of actions; free-text narration uses the proportional
    /// system font.
    @ViewBuilder
    private func stepRow(step: AgentStep) -> some View {
        let isToolish = isToolStep(step.description)
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: step.succeeded
                  ? "checkmark.circle.fill"
                  : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(step.succeeded
                                ? DS.Colors.success
                                : DS.Colors.destructive)
                // Pin the icon to the top of multi-line wrapped text.
                .padding(.top, 1)
            Text(step.description)
                .font(isToolish
                      ? .system(size: 11, design: .monospaced)
                      : .system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
    }

    /// Steps emitted by `runToolCallBatch` start with `→ tool_name(...)`
    /// for the invocation or three spaces for the result preview. Both
    /// look much better in a monospace font; free-form text steps
    /// (LLM narration, errors) use the proportional font.
    private func isToolStep(_ description: String) -> Bool {
        description.hasPrefix("→") || description.hasPrefix("   ")
    }

    // MARK: - Metrics

    private var metricsRow: some View {
        HStack {
            Text("Time: \(formattedElapsed)")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer()
            let stepCount = status.stepHistory.count
            Text("\(stepCount) step\(stepCount == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Interrupt field

    private var interruptSection: some View {
        HStack(spacing: 6) {
            TextField("Interrupt agent…", text: $interruptText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(DS.Colors.surface2)
                .cornerRadius(DS.CornerRadius.small)
                .onSubmit { sendInterrupt() }

            Button(action: sendInterrupt) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(interruptText.isEmpty ? DS.Colors.textTertiary : agentColor)
            }
            .buttonStyle(.plain)
            .disabled(interruptText.isEmpty)
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private var formattedElapsed: String {
        let totalSeconds = Int(status.elapsedSeconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private func sendInterrupt() {
        let trimmed = interruptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSendInterrupt(trimmed)
        interruptText = ""
    }
}
