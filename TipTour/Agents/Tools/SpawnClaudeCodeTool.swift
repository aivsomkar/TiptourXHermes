// TipTour/Agents/Tools/SpawnClaudeCodeTool.swift

import Foundation

/// Spawns a `claude --print` CLI subprocess to delegate a sub-task to Claude Code.
/// Useful for coding tasks where you want Claude Code's full tool-calling loop.
/// Requires `claude` to be installed (brew install anthropic-claude or npm i -g @anthropic-ai/claude-code).
struct SpawnClaudeCodeTool: AgentTool {

    let name = "spawn_claude_code"

    let description = """
        Delegate a coding or file-editing sub-task to Claude Code CLI via \
        `claude --print`. Claude Code will use its own tools (read/write files, \
        run shell, etc.) to complete the task and return a summary. \
        Use for complex multi-step coding tasks. Timeout: 120 seconds.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "task": {
                    "type": "string",
                    "description": "The task description to send to Claude Code."
                },
                "working_directory": {
                    "type": "string",
                    "description": "Absolute path of the directory to run Claude Code in. Defaults to user home."
                }
            },
            "required": ["task"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            guard let claudePath = resolveClaudePath() else {
                return """
                    Error: 'claude' CLI not found. Install it with:
                      brew install anthropic-ai/tap/claude
                    or:
                      npm install -g @anthropic-ai/claude-code
                    """
            }
            return await ShellRunner.run(
                command: "\(claudePath) --print \(shellEscape(args.task))",
                workingDirectory: args.workingDirectory,
                timeoutSeconds: 120
            )
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// Locates the `claude` binary by checking common install paths and PATH.
    private func resolveClaudePath() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/bin/claude",
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.npm-global/bin/claude",
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.local/bin/claude"
        ]
        let manager = FileManager.default
        for path in candidates where manager.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Single-quotes the string and escapes any internal single quotes.
    private func shellEscape(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct ParsedArgs {
        let task: String
        let workingDirectory: String?
    }

    private func parseArguments(from json: String) throws -> ParsedArgs {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let task = dict["task"] as? String, !task.isEmpty else {
            throw ToolArgumentError.missingRequiredField("task")
        }
        return ParsedArgs(task: task, workingDirectory: dict["working_directory"] as? String)
    }
}
