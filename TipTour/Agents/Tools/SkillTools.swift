// TipTour/Agents/Tools/SkillTools.swift

import Foundation

// MARK: - Save Skill Tool

struct SaveSkillTool: AgentTool {

    let name = "save_skill"
    let description = """
        Save the current task's tool call sequence as a reusable skill in the shared library. \
        Use when you've found a reliable procedure worth reusing. \
        Future agents can find it with recall_skill.
        """
    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Short kebab-case name for this skill (e.g. 'install-pnpm-deps')."
                },
                "description": {
                    "type": "string",
                    "description": "One sentence describing when to use this skill."
                }
            },
            "required": ["name", "description"]
        }
        """

    private let taskType: TaskType
    private let historyBuffer: ToolCallHistoryBuffer
    private let store: SkillLibraryStore

    init(taskType: TaskType, historyBuffer: ToolCallHistoryBuffer, store: SkillLibraryStore = SkillLibraryStore.shared) {
        self.taskType = taskType
        self.historyBuffer = historyBuffer
        self.store = store
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skillName = dict["name"] as? String, !skillName.isEmpty,
              let skillDescription = dict["description"] as? String, !skillDescription.isEmpty else {
            return "Error: \(ToolArgumentError.missingRequiredField("name or description").localizedDescription)"
        }
        let slug = SkillLibraryStore.generateSlug(from: skillName)
        let body = SkillBodyBuilder.build(
            name: skillName,
            toolCalls: historyBuffer.calls,
            resultSummary: skillDescription
        )
        await store.write(slug: slug, name: skillName, description: skillDescription, taskTypes: [taskType], body: body)
        return "Skill saved: \(skillName)"
    }
}

// MARK: - Recall Skill Tool

struct RecallSkillTool: AgentTool {

    let name = "recall_skill"
    let description = """
        Search the shared skill library for a procedure matching your goal. \
        Returns the full step-by-step skill document for the best match.
        """
    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Describe what you're trying to do. E.g. 'install node dependencies' or 'build xcode project'."
                }
            },
            "required": ["query"]
        }
        """

    private let taskType: TaskType
    private let store: SkillLibraryStore

    init(taskType: TaskType, store: SkillLibraryStore = SkillLibraryStore.shared) {
        self.taskType = taskType
        self.store = store
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = dict["query"] as? String, !query.isEmpty else {
            return "Error: \(ToolArgumentError.missingRequiredField("query").localizedDescription)"
        }
        let results = await store.query(taskDescription: query, taskTypes: [taskType], limit: 1)
        guard let top = results.first else { return "No matching skill found." }
        guard let body = await store.fetchBody(slug: top.slug) else {
            return "Error: skill file could not be read."
        }
        // Progressive disclosure: if this skill has additional resources
        // (references/templates/scripts/assets), advertise them at the
        // top so the agent knows to call `read_skill_resource` for the
        // body of any it needs. Keeps the initial recall response
        // small while still surfacing the full available context.
        let resources = await store.listResources(slug: top.slug)
        guard !resources.isEmpty else { return body }
        let header = """
        ## Available resources (use `read_skill_resource(slug: "\(top.slug)", relative_path: …)` to read)
        \(resources.map { "- \($0)" }.joined(separator: "\n"))

        ---

        """
        return header + body
    }
}

// MARK: - Read Skill Resource Tool (Phase C — progressive disclosure)

struct ReadSkillResourceTool: AgentTool {

    let name = "read_skill_resource"
    let description = """
        Read a single file inside a skill's folder by relative path. \
        Use this after recall_skill returns a list of available \
        references/templates/scripts/assets and you need their content. \
        Paths must be relative to the skill folder; absolute paths and \
        `..` are rejected.
        """
    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "slug": {
                    "type": "string",
                    "description": "The skill slug (folder name)."
                },
                "relative_path": {
                    "type": "string",
                    "description": "Path relative to the skill folder, e.g. 'references/REFERENCE.md'."
                }
            },
            "required": ["slug", "relative_path"]
        }
        """

    private let taskType: TaskType
    private let store: SkillLibraryStore

    init(taskType: TaskType, store: SkillLibraryStore = SkillLibraryStore.shared) {
        self.taskType = taskType
        self.store = store
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slug = dict["slug"] as? String, !slug.isEmpty,
              let relativePath = dict["relative_path"] as? String, !relativePath.isEmpty else {
            return "Error: arguments must be { slug: string, relative_path: string }"
        }
        guard let content = await store.fetchResource(slug: slug, relativePath: relativePath) else {
            return "Error: resource not found at \(slug)/\(relativePath) (or path was rejected for security)"
        }
        return content
    }
}
