// TipTour/Agents/UI/SettingsView.swift

import SwiftUI

// MARK: - Tab container

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .agents
    @Environment(\.dismiss) private var dismiss

    enum SettingsTab: String, CaseIterable {
        case agents = "Agents"
        case skills = "Skills"
        case learning = "Learning"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row: segmented tab picker + close button
            HStack(spacing: 12) {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .background(DS.Colors.borderSubtle)

            Group {
                switch selectedTab {
                case .agents:
                    AgentsSettingsView()
                case .skills:
                    SkillsSettingsView()
                case .learning:
                    LearningSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 440)
        .background(DS.Colors.surface1)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Agents tab

struct AgentsSettingsView: View {
    @State private var profiles: [TaskProfile] = []
    @State private var availableProviderIds: [String] = []
    @State private var isLoading = true
    @State private var maxConcurrentAgents: Int = UserDefaults.standard.object(forKey: "maxConcurrentAgents") as? Int ?? 5

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        settingsSectionHeader("Model Routing")
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                        ForEach(profiles.indices, id: \.self) { index in
                            taskProfileRow(profileIndex: index)
                            Divider()
                                .background(DS.Colors.borderSubtle)
                                .padding(.horizontal, 16)
                        }

                        settingsSectionHeader("Concurrency")
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                        HStack {
                            Text("Max concurrent agents")
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textSecondary)
                            Spacer()
                            Stepper("\(maxConcurrentAgents)", value: $maxConcurrentAgents, in: 1...10)
                                .font(.system(size: 12))
                                .onChange(of: maxConcurrentAgents) { _, newValue in
                                    UserDefaults.standard.set(newValue, forKey: "maxConcurrentAgents")
                                }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .task {
            profiles = await LLMProviderRegistry.shared.allProfiles()
            availableProviderIds = await LLMProviderRegistry.shared.allProviders().map(\.providerId).sorted()
            isLoading = false
        }
    }

    private func taskProfileRow(profileIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profiles[profileIndex].taskType.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(width: 130, alignment: .leading)

                Picker("", selection: Binding(
                    get: { profiles[profileIndex].preferredProviderId },
                    set: { newId in
                        profiles[profileIndex].preferredProviderId = newId
                        let updated = profiles[profileIndex]
                        Task { await LLMProviderRegistry.shared.setProfile(updated) }
                    }
                )) {
                    ForEach(availableProviderIds, id: \.self) { id in
                        Text(id).tag(id)
                    }
                    if !availableProviderIds.contains(profiles[profileIndex].preferredProviderId) {
                        Text(profiles[profileIndex].preferredProviderId)
                            .tag(profiles[profileIndex].preferredProviderId)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
            }

            HStack {
                Text("Token budget:")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("", value: Binding(
                    get: { profiles[profileIndex].tokenBudget },
                    set: { newBudget in
                        profiles[profileIndex].tokenBudget = newBudget
                        let updated = profiles[profileIndex]
                        Task { await LLMProviderRegistry.shared.setProfile(updated) }
                    }
                ), format: .number)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 70)
                .textFieldStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.05))
                )
                Text("tokens")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func settingsSectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.4)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.bottom, 4)
    }
}

// MARK: - Skills tab

struct SkillsSettingsView: View {
    @State private var skills: [SkillEntry] = []
    @State private var isLoading = true
    @State private var showClearConfirmation = false
    @State private var isImporting: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var importURL: String = ""
    @State private var importStatus: String?
    @State private var importError: String?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)

                Button("Import…") {
                    showImportSheet = true
                }
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textPrimary)
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(isImporting)

                Spacer()

                Button("Clear All") {
                    showClearConfirmation = true
                }
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.7))
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(skills.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()
                .background(DS.Colors.borderSubtle)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if skills.isEmpty {
                Text("No skills saved yet.\nSkills are created automatically when agents complete tasks, or by using the Record Demonstration feature.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(skills, id: \.id) { skill in
                            skillRow(skill: skill)
                            Divider()
                                .background(DS.Colors.borderSubtle)
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .task { await loadSkills() }
        .confirmationDialog(
            "Clear all \(skills.count) skills?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Skills", role: .destructive) {
                Task {
                    await SkillLibraryStore.shared.clear()
                    await loadSkills()
                }
            }
        } message: {
            Text("This cannot be undone.")
        }
        .sheet(isPresented: $showImportSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import skills from a GitHub repo")
                    .font(.system(size: 13, weight: .semibold))

                Text("Paste a public github.com URL. To import a subfolder, paste the tree URL — e.g. https://github.com/ruvnet/ruflo/tree/main/.agents/skills")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("https://github.com/owner/repo", text: $importURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isImporting)

                if let status = importStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                if let error = importError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        showImportSheet = false
                    }
                    .disabled(isImporting)
                    .pointerCursor()

                    Button(isImporting ? "Importing…" : "Import") {
                        Task { await runImport() }
                    }
                    .keyboardShortcut(.return)
                    .disabled(isImporting || importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointerCursor()
                }
            }
            .padding(20)
            .frame(width: 480)
        }
        .onChange(of: showImportSheet) { _, isPresented in
            if isPresented {
                importURL = ""
                importStatus = nil
                importError = nil
            }
        }
    }

    private func skillRow(skill: SkillEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(skill.taskTypes.map(\.displayName).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text("·")
                        .foregroundColor(DS.Colors.textTertiary)
                        .font(.system(size: 10))

                    Text(dateFormatter.string(from: skill.createdAt))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Button {
                Task {
                    await SkillLibraryStore.shared.delete(slug: skill.slug)
                    await loadSkills()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Delete this skill")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func loadSkills() async {
        isLoading = true
        skills = await SkillLibraryStore.shared.allEntries()
        isLoading = false
    }

    private func runImport() async {
        isImporting = true
        importError = nil
        importStatus = "Downloading and importing…"
        do {
            let trimmedURL = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let report = try await SkillImporter().importFrom(url: trimmedURL)
            importStatus = "Imported \(report.imported.count), skipped \(report.skipped.count), failed \(report.failed.count)."
            await loadSkills()
        } catch {
            importError = error.localizedDescription
            importStatus = nil
        }
        isImporting = false
    }
}

// MARK: - Learning tab

struct LearningSettingsView: View {
    @State private var selfCritiqueThreshold: Double =
        UserDefaults.standard.object(forKey: "selfCritiqueThreshold") as? Double ?? 0.4
    @State private var showClearMemoryConfirmation = false
    @State private var clearAllMemory = false
    @State private var memoryCleared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                settingsSectionHeader("Self-Critique")
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Inefficiency threshold")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer()
                        Text(String(format: "%.2f", selfCritiqueThreshold))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                    }

                    Slider(value: $selfCritiqueThreshold, in: 0.1...0.9, step: 0.05)
                        .onChange(of: selfCritiqueThreshold) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "selfCritiqueThreshold")
                        }

                    Text("When an agent's inefficiency score exceeds this threshold, TipTour makes one additional LLM call to rewrite the saved skill and log a lesson. Lower = more aggressive self-critique.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.horizontal, 16)

                settingsSectionHeader("Memory")
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Task-result memories expire after 7 days. Permanent facts (written by self-critique) never expire.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)

                    Button("Clear Task-Result Memories") {
                        clearAllMemory = false
                        showClearMemoryConfirmation = true
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.7))
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button("Clear All Memory (including permanent facts)") {
                        clearAllMemory = true
                        showClearMemoryConfirmation = true
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.7))
                    .buttonStyle(.plain)
                    .pointerCursor()

                    if memoryCleared {
                        Text("Memory cleared.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.horizontal, 16)

                settingsSectionHeader("Watch Me Shortcut")
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Text("Ctrl + Option + W")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)

                Text("Hold Ctrl + Option + W to begin recording a demonstration. Press again to stop. You will be prompted to name and save the recorded skill.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .confirmationDialog(
            clearAllMemory ? "Clear all memory including permanent facts?" : "Clear task-result memories?",
            isPresented: $showClearMemoryConfirmation,
            titleVisibility: .visible
        ) {
            Button(clearAllMemory ? "Clear All Memory" : "Clear Task-Result Memories", role: .destructive) {
                Task {
                    await AgentMemoryStore.shared.clear(keepPermanent: !clearAllMemory)
                    memoryCleared = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        memoryCleared = false
                    }
                }
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func settingsSectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.4)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.bottom, 4)
    }
}
