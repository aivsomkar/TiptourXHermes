// TipTour/Agents/Tools/MemoryTools.swift

import Foundation

// MARK: - Remember Fact Tool

struct RememberFactTool: AgentTool {

    let name = "remember_fact"
    let description = """
        Save a fact to shared agent memory so future agents can use it. \
        Use for durable environment facts: tool paths, project conventions, API base URLs. \
        Pass permanent: true for facts that will not change.
        """
    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "content": {
                    "type": "string",
                    "description": "The fact to remember. Be specific and self-contained — future agents will read this without your current context."
                },
                "permanent": {
                    "type": "boolean",
                    "description": "Set true for durable facts that won't change (tool paths, project conventions, env details). Defaults to false (expires in 30 days)."
                }
            },
            "required": ["content"]
        }
        """

    private let taskType: TaskType
    private let store: AgentMemoryStore

    init(taskType: TaskType, store: AgentMemoryStore = AgentMemoryStore.shared) {
        self.taskType = taskType
        self.store = store
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String, !content.isEmpty else {
            return "Error: \(ToolArgumentError.missingRequiredField("content").localizedDescription)"
        }
        let permanent = dict["permanent"] as? Bool ?? false
        await store.write(content: content, entryType: .fact, taskTypes: [taskType], permanent: permanent)
        return "Remembered: \(content)"
    }
}

// MARK: - Recall Facts Tool

struct RecallFactsTool: AgentTool {

    let name = "recall_facts"
    let description = """
        Search shared agent memory for relevant facts from previous tasks. \
        Use mid-task to check what other agents have already learned. \
        Returns up to 20 matches ordered by relevance.
        """
    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Describe what you're trying to find. E.g. 'homebrew path' or 'project build command'."
                }
            },
            "required": ["query"]
        }
        """

    private let taskType: TaskType
    private let store: AgentMemoryStore

    init(taskType: TaskType, store: AgentMemoryStore = AgentMemoryStore.shared) {
        self.taskType = taskType
        self.store = store
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = dict["query"] as? String, !query.isEmpty else {
            return "Error: \(ToolArgumentError.missingRequiredField("query").localizedDescription)"
        }
        let results = await store.query(taskDescription: query, taskTypes: [taskType])
        guard !results.isEmpty else { return "No matching memories found." }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return results.enumerated().map { index, entry in
            let typeLabel = entry.entryType == .fact ? "fact" : "task result"
            let expiryLabel: String
            if let expiresAt = entry.expiresAt {
                expiryLabel = "expires \(dateFormatter.string(from: expiresAt))"
            } else {
                expiryLabel = "permanent"
            }
            return "\(index + 1). \(entry.content) (\(typeLabel), \(expiryLabel))"
        }.joined(separator: "\n")
    }
}
