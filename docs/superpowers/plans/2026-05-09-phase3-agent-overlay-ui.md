# Phase 3: AgentOverlayStack UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a floating NSPanel stack anchored to the top-right of the screen that shows all active background agents with live status, step history, tokens/time, inline chat, and a "New Task" spawner.

**Architecture:** Four new files under `TipTour/Agents/Overlay/`. `AgentStateDisplay` is a pure helper struct that maps `AgentState` → display values (dot color, pulsing, icon). `AgentPanelView` is the SwiftUI view for a single agent (collapsed + expanded). `AgentOverlayStackView` is the root SwiftUI view that subscribes to `AgentSwarmManager.shared.overlayStatePublisher` and owns expand/dismiss UI state. `AgentOverlayWindowController` wraps everything in a non-activating NSPanel (same pattern as `MenuBarPanelManager`) anchored top-right.

**Tech Stack:** SwiftUI, AppKit (NSPanel, NSHostingView), Combine (`CurrentValueSubject`), Swift Testing.

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Overlay/AgentStateDisplay.swift` | Pure map: `AgentState` → dot variant, color, pulsing, SF symbol |
| Create | `TipTour/Agents/Overlay/AgentPanelView.swift` | SwiftUI for one agent: collapsed row + expanded detail + chat |
| Create | `TipTour/Agents/Overlay/AgentOverlayStackView.swift` | Root stack: subscribes to publisher, expand/dismiss state, new-task form |
| Create | `TipTour/Agents/Overlay/AgentOverlayWindowController.swift` | NSPanel host: top-right position, auto-resize height, show/hide |
| Create | `TipTourTests/AgentOverlayTests.swift` | Tests for AgentStateDisplay logic |
| Modify | `TipTour/TipTourApp.swift` | Create overlay controller in `applicationDidFinishLaunching` |
| Modify | `CLAUDE.md` | Add 4 overlay files to Key Files table |

---

## Task 1: AgentStateDisplay + Tests

**Files:**
- Create: `TipTour/Agents/Overlay/AgentStateDisplay.swift`
- Create: `TipTourTests/AgentOverlayTests.swift`

- [ ] **Step 1: Write the failing tests**

Open `TipTourTests/AgentOverlayTests.swift` and write:

```swift
// TipTourTests/AgentOverlayTests.swift

import Foundation
import Testing
@testable import TipTour

@Suite("AgentStateDisplay")
struct AgentStateDotVariantTests {

    @Test func spawnningIsGrey() {
        #expect(AgentStateDisplay.dotVariant(for: .spawning) == .grey)
    }

    @Test func activeIsGreenPulsing() {
        #expect(AgentStateDisplay.dotVariant(for: .active) == .greenPulsing)
    }

    @Test func busyIsBluePulsing() {
        #expect(AgentStateDisplay.dotVariant(for: .busy) == .bluePulsing)
    }

    @Test func blockedIsAmber() {
        let blocker = AgentBlocker(description: "Need login", possibleResolutions: [], raisedAt: Date())
        #expect(AgentStateDisplay.dotVariant(for: .blocked(blocker: blocker)) == .amber)
    }

    @Test func idleIsGrey() {
        #expect(AgentStateDisplay.dotVariant(for: .idle) == .grey)
    }

    @Test func completedIsGreen() {
        #expect(AgentStateDisplay.dotVariant(for: .completed) == .green)
    }

    @Test func errorIsRed() {
        #expect(AgentStateDisplay.dotVariant(for: .error(message: "boom")) == .red)
    }

    @Test func terminatedIsGrey() {
        #expect(AgentStateDisplay.dotVariant(for: .terminated) == .grey)
    }

    @Test func onlyActiveAndBusyArePulsing() {
        #expect(AgentStateDisplay.isPulsing(for: .greenPulsing) == true)
        #expect(AgentStateDisplay.isPulsing(for: .bluePulsing) == true)
        #expect(AgentStateDisplay.isPulsing(for: .amber) == false)
        #expect(AgentStateDisplay.isPulsing(for: .green) == false)
        #expect(AgentStateDisplay.isPulsing(for: .red) == false)
        #expect(AgentStateDisplay.isPulsing(for: .grey) == false)
    }

    @Test func statusIconIsNeverEmpty() {
        let states: [AgentState] = [
            .spawning, .active, .busy,
            .blocked(blocker: AgentBlocker(description: "x", possibleResolutions: [], raisedAt: Date())),
            .idle, .completed, .error(message: "e"), .terminated
        ]
        for state in states {
            #expect(!AgentStateDisplay.statusIcon(for: state).isEmpty,
                    "Empty icon for \(state)")
        }
    }
}

@Suite("AgentOverlayStack")
struct AgentOverlayStackTests {

    @Test func overlayLimitsVisibleAgentsToFive() {
        // Build 7 statuses
        let statuses: [AgentStatus] = (0..<7).map { index in
            AgentStatus(
                id: UUID(),
                agentName: "Agent \(index)",
                taskSummary: "Task \(index)",
                state: .active,
                currentStep: "Working",
                stepHistory: [],
                tokensUsed: 0,
                elapsedSeconds: 0,
                blocker: nil,
                result: nil,
                isExpanded: false,
                isMinimised: false,
                chatHistory: []
            )
        }
        let visible = AgentOverlayStackView.visibleStatuses(from: statuses)
        #expect(visible.count == 5)
    }

    @Test func overlayShowsAllAgentsWhenFiveOrFewer() {
        let statuses: [AgentStatus] = (0..<3).map { index in
            AgentStatus(
                id: UUID(),
                agentName: "Agent \(index)",
                taskSummary: "Task \(index)",
                state: .active,
                currentStep: "Working",
                stepHistory: [],
                tokensUsed: 0,
                elapsedSeconds: 0,
                blocker: nil,
                result: nil,
                isExpanded: false,
                isMinimised: false,
                chatHistory: []
            )
        }
        let visible = AgentOverlayStackView.visibleStatuses(from: statuses)
        #expect(visible.count == 3)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail (types not yet defined)**

Build target: `TipTourTests`. Expected: compile error — `AgentStateDisplay` and `AgentOverlayStackView.visibleStatuses` not found.

- [ ] **Step 3: Create AgentStateDisplay**

Create `TipTour/Agents/Overlay/AgentStateDisplay.swift`:

```swift
// TipTour/Agents/Overlay/AgentStateDisplay.swift

import SwiftUI

// MARK: - Dot variant enum (testable without SwiftUI Color equality)

enum AgentDotVariant: Equatable {
    case greenPulsing   // active — green + pulsing
    case bluePulsing    // busy — blue + pulsing
    case amber          // blocked
    case green          // completed (static)
    case red            // error
    case grey           // idle / spawning / terminated
}

// MARK: - Pure display logic

struct AgentStateDisplay {

    static func dotVariant(for state: AgentState) -> AgentDotVariant {
        switch state {
        case .spawning:     return .grey
        case .active:       return .greenPulsing
        case .busy:         return .bluePulsing
        case .blocked:      return .amber
        case .idle:         return .grey
        case .completed:    return .green
        case .error:        return .red
        case .terminated:   return .grey
        }
    }

    static func dotColor(for variant: AgentDotVariant) -> Color {
        switch variant {
        case .greenPulsing: return DS.Colors.success
        case .bluePulsing:  return DS.Colors.blue500
        case .amber:        return DS.Colors.warning
        case .green:        return DS.Colors.success
        case .red:          return DS.Colors.destructive
        case .grey:         return DS.Colors.textTertiary
        }
    }

    static func isPulsing(for variant: AgentDotVariant) -> Bool {
        variant == .greenPulsing || variant == .bluePulsing
    }

    /// SF Symbol name used in the collapsed row indicator.
    static func statusIcon(for state: AgentState) -> String {
        switch state {
        case .completed:    return "checkmark.circle.fill"
        case .error:        return "xmark.circle.fill"
        case .blocked:      return "exclamationmark.triangle.fill"
        default:            return "circle.fill"
        }
    }
}
```

- [ ] **Step 4: Add the `visibleStatuses` static helper to `AgentOverlayStackView` temporarily as a stub so tests compile**

We need `AgentOverlayStackView.visibleStatuses(from:)` to exist. We'll implement the full view in Task 3. For now, add a minimal file so the test compiles:

Create `TipTour/Agents/Overlay/AgentOverlayStackView.swift` with just the static helper (the full view body comes in Task 3):

```swift
// TipTour/Agents/Overlay/AgentOverlayStackView.swift

import Combine
import SwiftUI

struct AgentOverlayStackView: View {

    // MARK: - Static helper (tested in AgentOverlayTests)

    /// Returns the first 5 statuses for display. Expanded agents are prioritised,
    /// then active, then others. Max 5 to avoid screen clutter.
    static func visibleStatuses(from allStatuses: [AgentStatus]) -> [AgentStatus] {
        let expanded   = allStatuses.filter { $0.isExpanded }
        let active     = allStatuses.filter { !$0.isExpanded && $0.state == .active }
        let others     = allStatuses.filter { !$0.isExpanded && $0.state != .active }
        let ordered    = expanded + active + others
        return Array(ordered.prefix(5))
    }

    // MARK: - State

    @State private var agentStatuses: [AgentStatus] = []
    @State private var expandedIds: Set<UUID> = []
    @State private var pendingDismissals: [UUID: Task<Void, Never>] = [:]

    // New-task form state
    @State private var isNewTaskFormVisible: Bool = false
    @State private var newTaskText: String = ""
    @State private var newTaskType: TaskType = .generalMac

    var body: some View {
        // Placeholder — full implementation in Task 3
        Text("AgentOverlayStackView — Task 3")
    }
}
```

- [ ] **Step 5: Run tests — expect PASS**

Build `TipTourTests`. All `AgentStateDotVariantTests` and `AgentOverlayStackTests` tests should pass.

- [ ] **Step 6: Commit**

```bash
git add TipTour/Agents/Overlay/AgentStateDisplay.swift \
        TipTour/Agents/Overlay/AgentOverlayStackView.swift \
        TipTourTests/AgentOverlayTests.swift
git commit -m "feat: add AgentStateDisplay + stub AgentOverlayStackView with tests"
```

---

## Task 2: AgentPanelView

**Files:**
- Create: `TipTour/Agents/Overlay/AgentPanelView.swift`

- [ ] **Step 1: Create AgentPanelView**

Create `TipTour/Agents/Overlay/AgentPanelView.swift`:

```swift
// TipTour/Agents/Overlay/AgentPanelView.swift

import SwiftUI

/// Single agent panel. Renders either a compact collapsed row (44 pt tall)
/// or a full expanded card showing steps, tokens, elapsed time, and a chat field.
/// The caller owns expand/collapse state; this view is fully driven by props + callbacks.
struct AgentPanelView: View {

    let status: AgentStatus
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onDismiss: () -> Void
    let onSendChatMessage: (String) -> Void

    @State private var chatInputText: String = ""
    @State private var dotOpacity: Double = 1.0

    private var dotVariant: AgentDotVariant {
        AgentStateDisplay.dotVariant(for: status.state)
    }
    private var dotColor: Color {
        AgentStateDisplay.dotColor(for: dotVariant)
    }
    private var isPulsing: Bool {
        AgentStateDisplay.isPulsing(for: dotVariant)
    }

    var body: some View {
        VStack(spacing: 0) {
            collapsedRow
            if isExpanded {
                Divider()
                    .background(DS.Colors.borderSubtle)
                expandedDetail
            }
        }
        .background(DS.Colors.surface1)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Collapsed Row

    private var collapsedRow: some View {
        HStack(spacing: 8) {
            // State dot
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .opacity(isPulsing ? dotOpacity : 1.0)
                .onAppear { startPulseIfNeeded() }
                .onChange(of: isPulsing) { _, pulsing in
                    if pulsing { startPulseIfNeeded() } else { stopPulse() }
                }

            // Agent name + summary
            VStack(alignment: .leading, spacing: 1) {
                Text(status.agentName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(status.taskSummary)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            // Expand/collapse button
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())

            // Dismiss button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    // MARK: - Expanded Detail

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHistorySection
            Divider().background(DS.Colors.borderSubtle)
            metricsRow
            Divider().background(DS.Colors.borderSubtle)
            chatSection
        }
    }

    private var stepHistorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Steps")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            ForEach(status.stepHistory, id: \.description) { step in
                HStack(spacing: 6) {
                    Image(systemName: step.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(step.succeeded ? DS.Colors.success : DS.Colors.destructive)
                    Text(step.description)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
            }

            // Current in-progress step (if agent is active/busy)
            if !status.currentStep.isEmpty && status.state == .busy || status.state == .active {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 11, height: 11)
                    Text(status.currentStep)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
            }

            // Blocker message
            if let blocker = status.blocker {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warning)
                    Text(blocker.description)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }

            Spacer().frame(height: 10)
        }
    }

    private var metricsRow: some View {
        HStack {
            Text("Tokens: \(status.tokensUsed.formatted())")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            Text("·")
                .foregroundColor(DS.Colors.textTertiary)
                .font(.system(size: 10))
            Text("Time: \(formattedElapsed)")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Chat history
            if !status.chatHistory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(status.chatHistory.indices, id: \.self) { index in
                        let message = status.chatHistory[index]
                        HStack(alignment: .top, spacing: 6) {
                            Text(message.sender == .user ? "You" : "Agent")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(message.sender == .user
                                    ? DS.Colors.accentText
                                    : DS.Colors.textTertiary)
                                .frame(width: 34, alignment: .trailing)
                            Text(message.text)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.top, 6)
            }

            // Chat input
            HStack(spacing: 6) {
                TextField("Message this agent...", text: $chatInputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(DS.Colors.surface2)
                    .cornerRadius(6)
                    .onSubmit { sendChat() }

                Button(action: sendChat) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(chatInputText.isEmpty ? DS.Colors.textTertiary : DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(chatInputText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Helpers

    private var formattedElapsed: String {
        let totalSeconds = Int(status.elapsedSeconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private func sendChat() {
        let trimmed = chatInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSendChatMessage(trimmed)
        chatInputText = ""
    }

    private func startPulseIfNeeded() {
        guard isPulsing else { return }
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            dotOpacity = 0.3
        }
    }

    private func stopPulse() {
        withAnimation(.easeInOut(duration: 0.2)) {
            dotOpacity = 1.0
        }
    }
}
```

- [ ] **Step 2: Build the target to verify it compiles**

Open Xcode, press **Cmd+B**. Expected: build succeeds (SourceKit may show false-positive "cannot find type" errors for AgentTool/DS — these are PBXFileSystemSynchronizedRootGroup false positives; ignore them if the build itself passes).

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/Overlay/AgentPanelView.swift
git commit -m "feat: add AgentPanelView (collapsed + expanded + chat)"
```

---

## Task 3: AgentOverlayStackView (full implementation)

**Files:**
- Modify: `TipTour/Agents/Overlay/AgentOverlayStackView.swift`

Replace the placeholder body with the full implementation:

- [ ] **Step 1: Implement full AgentOverlayStackView**

Replace the entire content of `TipTour/Agents/Overlay/AgentOverlayStackView.swift`:

```swift
// TipTour/Agents/Overlay/AgentOverlayStackView.swift

import Combine
import SwiftUI

struct AgentOverlayStackView: View {

    // MARK: - Static helper (tested in AgentOverlayTests)

    /// Returns the first 5 statuses for display. Expanded agents are prioritised,
    /// then active, then others. Max 5 to avoid screen clutter.
    static func visibleStatuses(from allStatuses: [AgentStatus]) -> [AgentStatus] {
        let expanded = allStatuses.filter { $0.isExpanded }
        let active   = allStatuses.filter { !$0.isExpanded && $0.state == .active }
        let others   = allStatuses.filter { !$0.isExpanded && $0.state != .active }
        let ordered  = expanded + active + others
        return Array(ordered.prefix(5))
    }

    // MARK: - State

    @State private var agentStatuses: [AgentStatus] = []
    @State private var expandedIds: Set<UUID> = []
    /// Keyed by agent UUID — Task that fires terminate after 30s for completed agents.
    @State private var pendingDismissals: [UUID: Task<Void, Never>] = [:]

    // New-task form state
    @State private var isNewTaskFormVisible: Bool = false
    @State private var newTaskText: String = ""
    @State private var newTaskType: TaskType = .generalMac

    private let dismissDelaySeconds: Double

    /// `dismissDelaySeconds` is injectable for tests; production uses 30s.
    init(dismissDelaySeconds: Double = 30) {
        self.dismissDelaySeconds = dismissDelaySeconds
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let visible = Self.visibleStatuses(from: agentStatuses)

            ForEach(visible) { status in
                AgentPanelView(
                    status: status,
                    isExpanded: expandedIds.contains(status.id),
                    onToggleExpand: { toggleExpand(agentId: status.id) },
                    onDismiss: { dismiss(agentId: status.id) },
                    onSendChatMessage: { text in sendChat(text: text, toAgentId: status.id) }
                )
                .frame(width: 300)
            }

            newTaskRow
        }
        .padding(8)
        .onReceive(AgentSwarmManager.shared.overlayStatePublisher) { newStatuses in
            handleStatusUpdate(newStatuses: newStatuses)
        }
    }

    // MARK: - New Task Row

    private var newTaskRow: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isNewTaskFormVisible {
                newTaskForm
            }

            Button(action: { withAnimation { isNewTaskFormVisible.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: isNewTaskFormVisible ? "minus" : "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isNewTaskFormVisible ? "Cancel" : "New Task")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DS.Colors.surface1)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var newTaskForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Describe the task...", text: $newTaskText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(3, reservesSpace: false)
                .padding(8)
                .background(DS.Colors.surface2)
                .cornerRadius(6)
                .onSubmit { spawnNewTask() }

            HStack {
                Picker("Type", selection: $newTaskType) {
                    ForEach(TaskType.allCases, id: \.self) { taskType in
                        Text(taskType.displayName).tag(taskType)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: 11))
                .frame(maxWidth: 140)

                Spacer()

                Button("Spawn") {
                    spawnNewTask()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? DS.Colors.borderSubtle
                            : DS.Colors.accent)
                .cornerRadius(6)
                .disabled(newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(DS.Colors.surface1)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .frame(width: 300)
    }

    // MARK: - Actions

    private func toggleExpand(agentId: UUID) {
        if expandedIds.contains(agentId) {
            expandedIds.remove(agentId)
        } else {
            expandedIds.insert(agentId)
            // User expanded — cancel pending auto-dismiss for this agent.
            pendingDismissals[agentId]?.cancel()
            pendingDismissals.removeValue(forKey: agentId)
        }
    }

    private func dismiss(agentId: UUID) {
        pendingDismissals[agentId]?.cancel()
        pendingDismissals.removeValue(forKey: agentId)
        expandedIds.remove(agentId)
        Task { await AgentSwarmManager.shared.terminate(agentId) }
    }

    private func sendChat(text: String, toAgentId: UUID) {
        let message = AgentMessage(
            from: .main,
            to: .task(toAgentId),
            type: .chatMessage(text: text)
        )
        Task { await AgentSwarmManager.shared.send(message) }
    }

    private func spawnNewTask() {
        let trimmed = newTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await AgentSwarmManager.shared.spawn(
                taskDescription: trimmed,
                taskType: newTaskType
            )
        }
        newTaskText = ""
        withAnimation { isNewTaskFormVisible = false }
    }

    // MARK: - Publisher handling

    private func handleStatusUpdate(newStatuses: [AgentStatus]) {
        let previousStatuses = agentStatuses
        agentStatuses = newStatuses

        for status in newStatuses where status.state == .completed {
            let agentId = status.id
            // Only start timer if not already pending and not expanded.
            guard pendingDismissals[agentId] == nil, !expandedIds.contains(agentId) else { continue }
            let delay = dismissDelaySeconds
            let dismissTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, !expandedIds.contains(agentId) else { return }
                await AgentSwarmManager.shared.terminate(agentId)
            }
            pendingDismissals[agentId] = dismissTask
        }

        // Cancel timers for agents that are no longer completed (e.g. terminated externally).
        let completedIds = Set(newStatuses.filter { $0.state == .completed }.map(\.id))
        for pendingId in pendingDismissals.keys where !completedIds.contains(pendingId) {
            pendingDismissals[pendingId]?.cancel()
            pendingDismissals.removeValue(forKey: pendingId)
        }

        // Remove expand state for agents that have been removed from the swarm.
        let currentIds = Set(newStatuses.map(\.id))
        let previousIds = Set(previousStatuses.map(\.id))
        for removedId in previousIds.subtracting(currentIds) {
            expandedIds.remove(removedId)
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Cmd+B in Xcode. Expected: success.

- [ ] **Step 3: Run tests — still passing**

Cmd+U. All `AgentOverlayTests` tests should still pass (the static helper signature is unchanged).

- [ ] **Step 4: Commit**

```bash
git add TipTour/Agents/Overlay/AgentOverlayStackView.swift
git commit -m "feat: implement AgentOverlayStackView with publisher binding, auto-dismiss, and new-task form"
```

---

## Task 4: AgentOverlayWindowController

**Files:**
- Create: `TipTour/Agents/Overlay/AgentOverlayWindowController.swift`

- [ ] **Step 1: Create AgentOverlayWindowController**

Create `TipTour/Agents/Overlay/AgentOverlayWindowController.swift`:

```swift
// TipTour/Agents/Overlay/AgentOverlayWindowController.swift

import AppKit
import Combine
import SwiftUI

/// Hosts AgentOverlayStackView in a non-activating NSPanel anchored to the
/// top-right of the primary screen. Stays on top of all windows but never steals
/// focus. Auto-resizes height as the stack content grows or shrinks.
/// Uses the same NSPanel pattern as MenuBarPanelManager.
@MainActor
final class AgentOverlayWindowController {

    static let shared = AgentOverlayWindowController()

    private var panel: OverlayKeyablePanel?
    private var hostingView: NSHostingView<AgentOverlayStackView>?
    private var hostingViewSizeObservation: NSKeyValueObservation?
    private var overlayStateCancellable: AnyCancellable?

    /// Right-edge and top-edge margins (pt) from the visible screen frame.
    private let screenEdgeMargin: CGFloat = 8
    /// Fixed width of the panel.
    private let panelWidth: CGFloat = 316  // 300 content + 8 padding each side
    /// Maximum panel height — prevents runaway growth with many agents.
    private let maxPanelHeight: CGFloat = 600

    private init() {
        createPanel()
        subscribeToOverlayState()
    }

    // MARK: - Panel creation

    private func createPanel() {
        let stackView = AgentOverlayStackView()
        let hosting = NSHostingView(rootView: stackView)
        hosting.sizingOptions = .intrinsicContentSize
        self.hostingView = hosting

        let initialHeight: CGFloat = 60  // "New Task" button only
        let frame = initialFrame(height: initialHeight)

        let newPanel = OverlayKeyablePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.contentView = hosting
        self.panel = newPanel

        observeHostingViewSize()
    }

    // MARK: - Visibility driven by agent count

    private func subscribeToOverlayState() {
        overlayStateCancellable = AgentSwarmManager.shared.overlayStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.updateVisibility(agentCount: statuses.count)
            }
    }

    private func updateVisibility(agentCount: Int) {
        if agentCount > 0 {
            showPanel()
        } else {
            hidePanel()
        }
    }

    // MARK: - Show / Hide

    func showPanel() {
        guard let panel else { return }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        repositionPanel()
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    // MARK: - Positioning

    private func initialFrame(height: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: panelWidth, height: height)
        }
        let visibleFrame = screen.visibleFrame
        let panelX = visibleFrame.maxX - panelWidth - screenEdgeMargin
        let panelY = visibleFrame.maxY - height
        return NSRect(x: panelX, y: panelY, width: panelWidth, height: height)
    }

    private func repositionPanel() {
        guard let panel, let hostingView else { return }
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let fittingHeight = min(hostingView.fittingSize.height, maxPanelHeight)
        let panelX = visibleFrame.maxX - panelWidth - screenEdgeMargin
        let panelY = visibleFrame.maxY - fittingHeight
        panel.setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: fittingHeight),
                       display: true,
                       animate: false)
    }

    // MARK: - Auto-resize on content height change

    private func observeHostingViewSize() {
        guard let hostingView else { return }
        hostingViewSizeObservation = hostingView.observe(\.fittingSize, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async { self?.repositionPanel() }
        }
    }
}

// MARK: - NSPanel subclass

/// NSPanel subclass that becomes the key window so text fields (chat, new-task)
/// receive keyboard input, while still carrying the .nonactivatingPanel style
/// so it never steals app-activation focus.
private final class OverlayKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Cmd+B. Expected: success.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/Overlay/AgentOverlayWindowController.swift
git commit -m "feat: add AgentOverlayWindowController — non-activating NSPanel top-right"
```

---

## Task 5: Wire into app + CLAUDE.md

**Files:**
- Modify: `TipTour/TipTourApp.swift`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Create the overlay controller at app launch**

In `TipTour/TipTourApp.swift`, inside `CompanionAppDelegate`:

Add a property after `menuBarPanelManager`:
```swift
private var agentOverlayWindowController: AgentOverlayWindowController?
```

Inside `applicationDidFinishLaunching`, after the line `menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)`, add:
```swift
agentOverlayWindowController = AgentOverlayWindowController.shared
```

The full diff for `applicationDidFinishLaunching`:
```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    print("🎯 TipTour: Starting...")
    print("🎯 TipTour: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

    UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

    TipTourAnalytics.configure()
    TipTourAnalytics.trackAppOpened()

    menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
    agentOverlayWindowController = AgentOverlayWindowController.shared  // ← add this line
    companionManager.start()
    if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
        menuBarPanelManager?.showPanelOnLaunch()
    }
    registerAsLoginItemIfNeeded()
    startSparkleUpdater()
}
```

- [ ] **Step 2: Add property declaration to CompanionAppDelegate**

The full `CompanionAppDelegate` property block should become:
```swift
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private var agentOverlayWindowController: AgentOverlayWindowController?  // ← add
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    ...
}
```

- [ ] **Step 3: Build and confirm it compiles**

Cmd+B.

- [ ] **Step 4: Update CLAUDE.md Key Files table**

Add these 4 rows to the Key Files table (after the SpawnClaudeCodeTool row):

```
| `TipTour/Agents/Overlay/AgentStateDisplay.swift` | ~60 | Pure map: `AgentState` → `AgentDotVariant`, dot color, pulsing, SF symbol. Tested. |
| `TipTour/Agents/Overlay/AgentPanelView.swift` | ~220 | SwiftUI view for one agent: collapsed row (dot + name + buttons) + expanded detail (steps, metrics, chat). |
| `TipTour/Agents/Overlay/AgentOverlayStackView.swift` | ~180 | Root SwiftUI stack: subscribes to `overlayStatePublisher`, manages expand/dismiss state, 30s auto-dismiss timer, new-task form. |
| `TipTour/Agents/Overlay/AgentOverlayWindowController.swift` | ~120 | Non-activating NSPanel host anchored top-right. Shows when agents exist, auto-resizes height via `fittingSize` KVO. |
```

- [ ] **Step 5: Run full test suite**

Cmd+U. Expected: all `AgentSwarmTests`, `AgentToolTests`, and `AgentOverlayTests` pass.

- [ ] **Step 6: Commit**

```bash
git add TipTour/TipTourApp.swift CLAUDE.md
git commit -m "feat: wire AgentOverlayWindowController into app launch"
```

---

## Self-Review

**Spec coverage check (Section 8 of design spec):**

| Requirement | Covered by |
|---|---|
| Floating panel stack top-right, non-activating | Task 4: `AgentOverlayWindowController` |
| Green pulsing dot = active | Task 1: `AgentStateDisplay.dotVariant` |
| Amber dot = blocked | Task 1: `AgentStateDisplay.dotVariant` |
| Collapsed row: name, dot, [−][×] | Task 2: `AgentPanelView.collapsedRow` |
| Expanded: step history | Task 2: `AgentPanelView.stepHistorySection` |
| Expanded: tokens + time | Task 2: `AgentPanelView.metricsRow` |
| Expanded: chat with agent | Task 2: `AgentPanelView.chatSection` |
| Max 5 panels visible | Task 3: `AgentOverlayStackView.visibleStatuses` |
| Completed auto-dismiss 30s | Task 3: `handleStatusUpdate` timer logic |
| [+ New Task] button | Task 3: `AgentOverlayStackView.newTaskRow` |
| Can become key (text input works) | Task 4: `OverlayKeyablePanel.canBecomeKey` |
| Publisher-driven updates | Task 3: `.onReceive(overlayStatePublisher)` |

**No placeholders found.**

**Type consistency:** `AgentDotVariant` defined in Task 1, used in Task 2. `AgentOverlayStackView.visibleStatuses` defined in Task 1 stub, unchanged in Task 3. `OverlayKeyablePanel` is private to Task 4.
