// TipTour/Agents/Tools/AgentTool.swift

import Foundation

// MARK: - Protocol every agent tool implements

/// A single capability an agent can invoke. Conforms to Sendable so it can
/// be stored in a ToolBox that crosses actor boundaries.
protocol AgentTool: Sendable {
    /// The snake_case function name the LLM uses when calling this tool.
    var name: String { get }
    /// Plain-English description the LLM sees. Be specific about what the tool
    /// returns and any limits (e.g. character limits, timeout).
    var description: String { get }
    /// JSON Schema string for the tool's parameter object.
    /// Example: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}"
    var parametersJSON: String { get }

    /// Execute the tool. `argumentsJSON` is the raw JSON string from LLMToolCall.argumentsJSON.
    /// Returns a plain-text result appended to the conversation as a tool message.
    /// Implementations must not throw — catch errors and return a descriptive error string.
    func execute(argumentsJSON: String) async -> String
}

// MARK: - Shared argument parsing error

enum ToolArgumentError: Error, LocalizedError {
    case missingRequiredField(String)
    case invalidFieldValue(field: String, reason: String)
    case malformedJSON

    var errorDescription: String? {
        switch self {
        case .missingRequiredField(let field):
            return "Missing required argument '\(field)'"
        case .invalidFieldValue(let field, let reason):
            return "Invalid value for '\(field)': \(reason)"
        case .malformedJSON:
            return "Tool arguments are not valid JSON"
        }
    }
}

// MARK: - Container that holds a set of tools for one agent

/// Value type so it crosses actor boundaries without needing @Sendable annotations.
struct ToolBox: Sendable {

    private let tools: [any AgentTool]

    init(tools: [any AgentTool] = []) {
        assert(
            Set(tools.map(\.name)).count == tools.count,
            "ToolBox contains duplicate tool names: \(tools.map(\.name))"
        )
        self.tools = tools
    }

    /// The LLMTool definitions to pass to the provider at the start of each loop iteration.
    var definitions: [LLMTool] {
        tools.map { LLMTool(name: $0.name, description: $0.description, parametersJSON: $0.parametersJSON) }
    }

    /// Dispatch a tool call. Never throws — always returns a string the agent can reason from.
    func execute(toolCall: LLMToolCall) async -> String {
        guard let tool = tools.first(where: { $0.name == toolCall.name }) else {
            let available = tools.map(\.name).joined(separator: ", ")
            return "Error: unknown tool '\(toolCall.name)'. Available: \(available)"
        }
        return await tool.execute(argumentsJSON: toolCall.argumentsJSON)
    }

    // MARK: - Factory: builds the right tool set for each task type

    static func build(for taskType: TaskType) -> ToolBox {
        let sharedTools: [any AgentTool] = [
            RememberFactTool(taskType: taskType),
            RecallFactsTool(taskType: taskType),
            RecallSkillTool(taskType: taskType),
            ReadSkillResourceTool(taskType: taskType)
        ]
        return ToolBox(tools: domainTools(for: taskType) + sharedTools)
    }

    /// Builds the full toolbox including SaveSkillTool wired to the given history buffer.
    /// TaskAgent calls this overload so save_skill can snapshot the agent's live tool call history.
    static func build(for taskType: TaskType, historyBuffer: ToolCallHistoryBuffer) -> ToolBox {
        let sharedTools: [any AgentTool] = [
            RememberFactTool(taskType: taskType),
            RecallFactsTool(taskType: taskType),
            SaveSkillTool(taskType: taskType, historyBuffer: historyBuffer),
            RecallSkillTool(taskType: taskType),
            ReadSkillResourceTool(taskType: taskType)
        ]
        return ToolBox(tools: domainTools(for: taskType) + sharedTools)
    }

    /// Full overload that also wires the per-agent interactive shell
    /// session into the toolbox. The session is shared across every
    /// `interactive_shell` call within the agent so working directory,
    /// exported env vars, and aliases persist between commands.
    /// `workspaceURL` is the agent's per-task directory under
    /// `~/Library/Application Support/TipTour/agent-workspaces/<id>/`;
    /// agents can rely on it being writable and isolated from other
    /// agents' workspaces.
    static func build(
        for taskType: TaskType,
        historyBuffer: ToolCallHistoryBuffer,
        interactiveShellSession: InteractiveShellSession,
        workspaceURL: URL?
    ) -> ToolBox {
        let sharedTools: [any AgentTool] = [
            RememberFactTool(taskType: taskType),
            RecallFactsTool(taskType: taskType),
            SaveSkillTool(taskType: taskType, historyBuffer: historyBuffer),
            RecallSkillTool(taskType: taskType),
            ReadSkillResourceTool(taskType: taskType)
        ]
        var domain = domainTools(for: taskType)
        // Persistent shell is most valuable for coding / file work /
        // general Mac automation where state carries across commands.
        // Add it alongside the existing one-shot RunShellCommandTool so
        // the agent can pick: cheap & isolated (run_shell_command) vs
        // stateful & faster for chains (interactive_shell).
        switch taskType {
        case .coding, .fileManagement, .generalMac, .browserResearch:
            domain.append(InteractiveShellTool(session: interactiveShellSession))
        default:
            break
        }
        return ToolBox(tools: domain + sharedTools)
    }

    private static func domainTools(for taskType: TaskType) -> [any AgentTool] {
        switch taskType {
        case .coding:
            return [RunShellCommandTool(), ReadFileTool(), WriteFileTool(), ListDirectoryTool(), SpawnClaudeCodeTool()]

        case .browserResearch:
            // SmartClickTool consults AppChannelRegistry to auto-pick the
            // best channel (AppleScript / AXPress / cursor click) per
            // action. Lower-level primitives stay in the toolbox as
            // escape hatches when the LLM wants a specific channel.
            // Browsers with dedicated AppleScript adapters: Chrome,
            // Safari. Arc / Brave / Edge / Firefox use AppleScriptTool
            // (generic) + AX. SystemEvents is the universal UI-scripting
            // fallback when an app exposes neither.
            return [
                SmartClickTool(),
                ChromeControlTool(),
                SafariControlTool(),
                SystemEventsTool(),
                AppleScriptTool(),
                OpenURLTool(),
                ReadAXTreeTool(),
                AXPressElementTool(),
                ClickElementTool(),
                TypeTextTool(),
                PressKeyboardShortcutTool(),
                WebFetchTool(),
                WebSearchTool()
            ]

        case .fileManagement:
            return [ReadFileTool(), WriteFileTool(), ListDirectoryTool(), RunShellCommandTool()]

        case .generalMac:
            // Full keyboard + mouse + URL capability so an agent can drive
            // any macOS app start-to-finish. SmartClickTool consults
            // AppChannelRegistry to pick the lowest-friction click path
            // per app. Primitives stay available as escape hatches.
            // SystemEventsTool is the universal escape hatch for apps
            // with no AppleScript dictionary.
            return [
                SmartClickTool(),
                ReadAXTreeTool(),
                AXPressElementTool(),
                ClickElementTool(),
                TypeTextTool(),
                PressKeyboardShortcutTool(),
                OpenURLTool(),
                AppleScriptTool(),
                SystemEventsTool(),
                ChromeControlTool(),
                SafariControlTool(),
                RunShellCommandTool(),
                ReadFileTool(),
                WriteFileTool()
            ]

        case .analysis:
            return [ReadFileTool(), ListDirectoryTool(), WebFetchTool()]
        case .writing:
            return [ReadFileTool(), WriteFileTool(), WebFetchTool()]
        case .imageGeneration:
            return [GenerateImageTool(), RunShellCommandTool()]
        case .videoGeneration:
            return [GenerateVideoTool(), RunShellCommandTool()]
        }
    }
}
