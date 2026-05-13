// TipTour/Agents/Overlay/AgentOverlayStackView.swift

import Combine
import SwiftUI

struct AgentOverlayStackView: View {

    // MARK: - Static helper (tested in AgentOverlayTests)

    /// Returns up to 5 statuses ordered: active/busy first, then blocked,
    /// then other states. Max 5 prevents screen clutter.
    static func visibleStatuses(from allStatuses: [AgentStatus]) -> [AgentStatus] {
        func priorityRank(_ state: AgentState) -> Int {
            switch state {
            case .active, .busy:    return 0
            case .blocked:          return 1
            default:                return 2
            }
        }
        let sorted = allStatuses.sorted { priorityRank($0.state) < priorityRank($1.state) }
        return Array(sorted.prefix(5))
    }

    // MARK: - State

    @State private var agentStatuses: [AgentStatus] = []
    @State private var selectedAgentId: UUID? = nil

    // New-task form state
    @State private var isNewTaskFormVisible: Bool = false
    @State private var newTaskText: String = ""
    @State private var newTaskType: TaskType = .generalMac

    /// Retained as an init parameter for source compatibility with
    /// existing tests but no longer drives any behavior — completed
    /// agents now stay in the overlay until the user explicitly
    /// dismisses them via the × button.
    private let dismissDelaySeconds: Double

    /// `dismissDelaySeconds` is accepted but ignored — see the property
    /// docs above. The panel is now fixed-size so SwiftUI no longer
    /// needs to publish content-size changes back to AppKit.
    init(dismissDelaySeconds: Double = 30) {
        self.dismissDelaySeconds = dismissDelaySeconds
    }

    var body: some View {
        let visible = Self.visibleStatuses(from: agentStatuses)

        VStack(alignment: .leading, spacing: 8) {
            if !visible.isEmpty {
                // Vertical column of agent reactor rows — one per active agent.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { colorIndex, status in
                        AgentReactorButton(
                            status: status,
                            agentColor: agentReactorColorPalette[colorIndex % agentReactorColorPalette.count],
                            isSelected: selectedAgentId == status.id,
                            onTap: { toggleSelected(agentId: status.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            // Detail card slides in below the reactor row when an agent is selected.
            if let selectedId = selectedAgentId,
               let selectedStatus = visible.first(where: { $0.id == selectedId }),
               let colorIndex = visible.firstIndex(where: { $0.id == selectedId }) {
                AgentDetailCard(
                    status: selectedStatus,
                    agentColor: agentReactorColorPalette[colorIndex % agentReactorColorPalette.count],
                    onDismiss: { dismiss(agentId: selectedId) },
                    onSendInterrupt: { text in sendChat(text: text, toAgentId: selectedId) }
                )
                .frame(width: 300)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            newTaskRow
        }
        .padding(8)
        // Top-align inside the fixed-size hosting view. The panel is
        // 316×600 but the VStack only takes its natural height — the
        // remaining vertical space stays empty/transparent at the
        // bottom rather than vertically centering the content.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedAgentId)
        .onReceive(AgentSwarmManager.shared.overlayStatePublisher) { newStatuses in
            handleStatusUpdate(newStatuses: newStatuses)
        }
    }

    // MARK: - New Task Row

    private var newTaskTextIsEmpty: Bool {
        newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                .cornerRadius(DS.CornerRadius.medium)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
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
                .cornerRadius(DS.CornerRadius.small)
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
                .background(newTaskTextIsEmpty
                            ? DS.Colors.borderSubtle
                            : DS.Colors.accent)
                .cornerRadius(DS.CornerRadius.small)
                .disabled(newTaskTextIsEmpty)
                .pointerCursor()
            }
        }
        .padding(10)
        .background(DS.Colors.surface1)
        .cornerRadius(DS.CornerRadius.large)
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .frame(width: 300)
    }

    // MARK: - Actions

    private func toggleSelected(agentId: UUID) {
        if selectedAgentId == agentId {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedAgentId = nil
            }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedAgentId = agentId
            }
        }
    }

    private func dismiss(agentId: UUID) {
        if selectedAgentId == agentId {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedAgentId = nil
            }
        }
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
        let previousIds = Set(agentStatuses.map(\.id))
        // Capture previous error IDs before overwriting state.
        let previousErrorIds = Set(agentStatuses.filter { if case .error = $0.state { return true }; return false }.map(\.id))
        agentStatuses = newStatuses

        // Auto-expand the first newly-errored agent so the operator sees it
        // immediately. Switching selection to the new error works even when
        // another card is open, so concurrent errors aren't invisible.
        for status in newStatuses {
            if case .error = status.state, !previousErrorIds.contains(status.id) {
                let alreadyInspectingThisError = (selectedAgentId == status.id)
                if alreadyInspectingThisError { break }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedAgentId = status.id
                }
                break
            }
        }

        // NOTE: completed agents are intentionally NOT auto-dismissed.
        // They stay in the overlay until the user explicitly clicks the
        // × on the detail card. This lets the user inspect step history,
        // metrics, and the final summary at their own pace without a
        // hidden timer ripping it away mid-read. The previous 30s
        // auto-dismiss made completed agents disappear before the user
        // could check what they did.

        // If the selected agent was removed from the swarm, clear the selection.
        let currentIds = Set(newStatuses.map(\.id))
        for removedId in previousIds.subtracting(currentIds) {
            if selectedAgentId == removedId {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedAgentId = nil
                }
            }
        }
    }
}

