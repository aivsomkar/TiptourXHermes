// TipTour/Agents/Core/LLMProviderRegistry.swift

import Foundation

// MARK: - Task types agents can be assigned

enum TaskType: String, CaseIterable, Codable, Sendable {
    case coding
    case browserResearch
    case imageGeneration
    case videoGeneration
    case fileManagement
    case generalMac
    case analysis
    case writing

    var displayName: String {
        switch self {
        case .coding: return "Coding"
        case .browserResearch: return "Browser Research"
        case .imageGeneration: return "Image Generation"
        case .videoGeneration: return "Video Generation"
        case .fileManagement: return "File Management"
        case .generalMac: return "General Mac"
        case .analysis: return "Analysis"
        case .writing: return "Writing"
        }
    }
}

// MARK: - Per-task configuration: preferred model + token budget

struct TaskProfile: Codable, Sendable {
    var taskType: TaskType
    var preferredProviderId: String
    var fallbackProviderId: String?
    var tokenBudget: Int

    static func defaults() -> [TaskType: TaskProfile] {
        [
            .coding:           TaskProfile(taskType: .coding,           preferredProviderId: "anthropic-claude-sonnet-4-6",   tokenBudget: 32_000),
            .browserResearch:  TaskProfile(taskType: .browserResearch,  preferredProviderId: "openai-gpt-4o",                 fallbackProviderId: "gemini-rest-gemini-2.5-flash", tokenBudget: 8_000),
            .imageGeneration:  TaskProfile(taskType: .imageGeneration,  preferredProviderId: "openai-gpt-4o",                 tokenBudget: 2_000),
            .videoGeneration:  TaskProfile(taskType: .videoGeneration,  preferredProviderId: "gemini-rest-gemini-2.5-pro",    tokenBudget: 4_000),
            .fileManagement:   TaskProfile(taskType: .fileManagement,   preferredProviderId: "anthropic-claude-haiku-4-5",    tokenBudget: 4_000),
            .generalMac:       TaskProfile(taskType: .generalMac,       preferredProviderId: "anthropic-claude-sonnet-4-6",   tokenBudget: 8_000),
            .analysis:         TaskProfile(taskType: .analysis,         preferredProviderId: "anthropic-claude-opus-4-7",     tokenBudget: 16_000),
            .writing:          TaskProfile(taskType: .writing,          preferredProviderId: "anthropic-claude-sonnet-4-6",   tokenBudget: 8_000),
        ]
    }
}

// MARK: - Registry: holds all providers and routes task types to them

actor LLMProviderRegistry {

    static let shared = LLMProviderRegistry()

    private var providers: [String: any LLMProvider] = [:]
    private var taskProfiles: [TaskType: TaskProfile]
    private let userDefaults: UserDefaults
    private static let userDefaultsKey = "taskProfiles"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.taskProfiles = TaskProfile.defaults()
        // Merge persisted profiles over the defaults so new task types introduced
        // in app updates still get a default even if the user's persisted data predates them.
        if let data = userDefaults.data(forKey: Self.userDefaultsKey),
           let persisted = try? JSONDecoder().decode([TaskProfile].self, from: data) {
            for profile in persisted {
                self.taskProfiles[profile.taskType] = profile
            }
        }
    }

    // MARK: - Provider registration

    func register(_ provider: any LLMProvider) {
        providers[provider.providerId] = provider
    }

    /// Resolve the provider configured for a given task type. Returns
    /// nil when neither the preferred nor the fallback provider is
    /// registered — callers (`AgentSwarmManager.spawn`, `TaskAgent.run`)
    /// surface that as a clean "no provider configured for X" error so
    /// the user can fix their API keys.
    ///
    /// Earlier versions fell back to `providers.values.first`, which
    /// quietly routed coding tasks to whatever provider happened to be
    /// configured (often `gpt-4o-mini`) when the user removed the
    /// Anthropic key. That silent substitution made debugging "why is
    /// my code agent suddenly worse" basically impossible.
    func provider(for taskType: TaskType) -> (any LLMProvider)? {
        let profile = taskProfiles[taskType]
        if let primaryId = profile?.preferredProviderId,
           let primary = providers[primaryId] { return primary }
        if let fallbackId = profile?.fallbackProviderId,
           let fallback = providers[fallbackId] { return fallback }
        return nil
    }

    func provider(id: String) -> (any LLMProvider)? {
        providers[id]
    }

    func allProviders() -> [any LLMProvider] {
        Array(providers.values)
    }

    func voiceCapableProviders() -> [any LLMProvider] {
        providers.values.filter { $0.supportsVoice }
    }

    // MARK: - Profile management

    func profile(for taskType: TaskType) -> TaskProfile? {
        taskProfiles[taskType]
    }

    func setProfile(_ profile: TaskProfile) {
        taskProfiles[profile.taskType] = profile
        persistProfiles()
    }

    func allProfiles() -> [TaskProfile] {
        Array(taskProfiles.values).sorted { $0.taskType.rawValue < $1.taskType.rawValue }
    }

    // MARK: - Private

    private func persistProfiles() {
        let profiles = Array(taskProfiles.values)
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }
}

// MARK: - Keychain bootstrap

extension LLMProviderRegistry {

    func bootstrapFromKeychain() async {
        // Register every model the user can pick from in Settings →
        // Agents → "preferred provider". The UI iterates `allProviders()`
        // and shows every registered ID in every task type's picker,
        // so any model added here is immediately selectable for any
        // agent.
        //
        // We register models speculatively even when we're not sure
        // the user's API tier has access — calls to unauthorized
        // models surface as a 4xx from the provider at request time,
        // which TaskAgent's error path reports cleanly. That's strictly
        // better UX than hiding models the user might actually have
        // access to. Anything that 404s here is just an unused picker
        // entry, not a hard failure.
        //
        // Naming convention: providerId is `<vendor>-<modelId>` so the
        // Settings picker stays sortable and the user can tell at a
        // glance which vendor owns which entry.

        if let anthropicKey = KeychainStore.anthropicAPIKey, !anthropicKey.isEmpty {
            // Current Claude 4.x family (late-2025 release cadence).
            await register(AnthropicProvider(modelId: "claude-haiku-4-5",        apiKey: anthropicKey))
            await register(AnthropicProvider(modelId: "claude-sonnet-4-5",       apiKey: anthropicKey))
            await register(AnthropicProvider(modelId: "claude-sonnet-4-6",       apiKey: anthropicKey))
            await register(AnthropicProvider(modelId: "claude-opus-4-5",         apiKey: anthropicKey))
            await register(AnthropicProvider(modelId: "claude-opus-4-6",         apiKey: anthropicKey))
            await register(AnthropicProvider(modelId: "claude-opus-4-7",         apiKey: anthropicKey))
            // Legacy 3.5 still online for users with workflows pinned to it.
            await register(AnthropicProvider(modelId: "claude-3-5-sonnet-latest", apiKey: anthropicKey))
            await register(AnthropicProvider(modelId: "claude-3-5-haiku-latest",  apiKey: anthropicKey))
        }

        if let openAIKey = KeychainStore.openAIAPIKey, !openAIKey.isEmpty {
            // GPT-4o family.
            await register(OpenAIProvider(modelId: "gpt-4o",          apiKey: openAIKey))
            await register(OpenAIProvider(modelId: "gpt-4o-mini",     apiKey: openAIKey))
            await register(OpenAIProvider(modelId: "gpt-4-turbo",     apiKey: openAIKey))
            // GPT-5 family.
            await register(OpenAIProvider(modelId: "gpt-5",           apiKey: openAIKey))
            await register(OpenAIProvider(modelId: "gpt-5-mini",      apiKey: openAIKey))
            // o-series reasoning models. These take longer per call
            // but produce notably better results on coding / analysis
            // / planning tasks that benefit from chain-of-thought.
            await register(OpenAIProvider(modelId: "o1",              apiKey: openAIKey))
            await register(OpenAIProvider(modelId: "o1-mini",         apiKey: openAIKey))
            await register(OpenAIProvider(modelId: "o3",              apiKey: openAIKey))
            await register(OpenAIProvider(modelId: "o3-mini",         apiKey: openAIKey))
        }

        if let geminiKey = KeychainStore.geminiAPIKey, !geminiKey.isEmpty {
            // 2.0 family (older, still on the free tier).
            await register(GeminiRestProvider(modelId: "gemini-2.0-flash",         apiKey: geminiKey))
            await register(GeminiRestProvider(modelId: "gemini-2.0-flash-lite",    apiKey: geminiKey))
            // 2.5 family — broadly available on the free tier; best
            // free-tier option for tasks that need tool use is 2.5-pro.
            await register(GeminiRestProvider(modelId: "gemini-2.5-flash",         apiKey: geminiKey))
            await register(GeminiRestProvider(modelId: "gemini-2.5-flash-lite",    apiKey: geminiKey))
            await register(GeminiRestProvider(modelId: "gemini-2.5-pro",           apiKey: geminiKey))
            // 3.x family. Preview is the rolling release Google
            // promotes alongside GA. If a model is gated to a paid
            // tier the user's API key isn't on, the call will return
            // 403/404 and TaskAgent reports it — adjust these IDs in
            // GeminiRestProvider's URL pattern if Google renames them.
            await register(GeminiRestProvider(modelId: "gemini-3-flash-preview",   apiKey: geminiKey))
            await register(GeminiRestProvider(modelId: "gemini-3-flash",           apiKey: geminiKey))
            await register(GeminiRestProvider(modelId: "gemini-3-pro-preview",     apiKey: geminiKey))
            await register(GeminiRestProvider(modelId: "gemini-3-pro",             apiKey: geminiKey))
            // Rolling-alias channels Google sometimes exposes — useful
            // if the user wants "latest stable" without picking a
            // version. Falls back gracefully if Google retires them.
            await register(GeminiRestProvider(modelId: "gemini-flash-latest",      apiKey: geminiKey))
            await register(GeminiRestProvider(modelId: "gemini-pro-latest",        apiKey: geminiKey))
        }

        // One-line startup diagnostic so the user can confirm which
        // models actually got registered. Mirrors the per-agent
        // startup line in TaskAgent.run().
        let registered = await allProviders().map(\.providerId).sorted()
        print("[LLMProviderRegistry] bootstrapped \(registered.count) provider(s):")
        for providerId in registered {
            print("[LLMProviderRegistry]   - \(providerId)")
        }
    }
}
