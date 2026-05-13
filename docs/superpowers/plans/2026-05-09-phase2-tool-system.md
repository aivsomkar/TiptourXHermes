# Phase 2: Agent Tool System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give TaskAgents real tools — shell commands, file I/O, web fetch/search, macOS AX tree reads, UI clicks, and Claude Code CLI — replacing the Phase 1 stubs in TaskAgent.

**Architecture:** `AgentTool` protocol + `ToolBox` factory struct → 9 concrete tool implementations in `TipTour/Agents/Tools/` → `ToolBox` replaces the `availableToolDefinitions()` / `dispatchToolCall()` stubs in `TaskAgent`; `AgentSwarmManager.spawn()` builds the right `ToolBox` per task type at spawn time.

**Tech Stack:** Swift actors, Foundation.Process, URLSession async/await, macOS Accessibility APIs (ApplicationServices), CGEvent via the existing `ActionExecutor.shared` (@MainActor), existing `AccessibilityTreeResolver`.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Tools/AgentTool.swift` | `AgentTool` protocol, `ToolBox` struct, `ToolArgumentError` |
| Create | `TipTour/Agents/Tools/ShellTool.swift` | `RunShellCommandTool` — `/bin/zsh -c` with 30s timeout |
| Create | `TipTour/Agents/Tools/FileTools.swift` | `ReadFileTool`, `WriteFileTool`, `ListDirectoryTool` |
| Create | `TipTour/Agents/Tools/WebTools.swift` | `WebFetchTool`, `WebSearchTool` (DuckDuckGo Instant API) |
| Create | `TipTour/Agents/Tools/MacControlTools.swift` | `ReadAXTreeTool`, `ClickElementTool` (uses existing AX + ActionExecutor) |
| Create | `TipTour/Agents/Tools/SpawnClaudeCodeTool.swift` | `SpawnClaudeCodeTool` — `claude --print` subprocess |
| Modify | `TipTour/Agents/Swarm/TaskAgent.swift` | Add `toolBox: ToolBox` property + init param; replace stubs (lines 202–208) |
| Modify | `TipTour/Agents/Swarm/AgentSwarmManager.swift` | Build `ToolBox.build(for: taskType)` at spawn (lines 31–38) |
| Create | `TipTourTests/AgentToolTests.swift` | All tool tests |
| Modify | `CLAUDE.md` | Add new files to Key Files table |

---

## Task 1: AgentTool Protocol + ToolBox

**Files:**
- Create: `TipTour/Agents/Tools/AgentTool.swift`

- [ ] **Step 1: Create the file**

```swift
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
        switch taskType {
        case .coding:
            return ToolBox(tools: [
                RunShellCommandTool(),
                ReadFileTool(),
                WriteFileTool(),
                ListDirectoryTool(),
                SpawnClaudeCodeTool()
            ])
        case .browserResearch:
            return ToolBox(tools: [
                WebFetchTool(),
                WebSearchTool()
            ])
        case .fileManagement:
            return ToolBox(tools: [
                ReadFileTool(),
                WriteFileTool(),
                ListDirectoryTool(),
                RunShellCommandTool()
            ])
        case .generalMac:
            return ToolBox(tools: [
                ReadAXTreeTool(),
                ClickElementTool(),
                RunShellCommandTool(),
                ReadFileTool(),
                WriteFileTool()
            ])
        case .analysis:
            return ToolBox(tools: [
                ReadFileTool(),
                ListDirectoryTool(),
                WebFetchTool()
            ])
        case .writing:
            return ToolBox(tools: [
                ReadFileTool(),
                WriteFileTool(),
                WebFetchTool()
            ])
        case .imageGeneration, .videoGeneration:
            return ToolBox(tools: [RunShellCommandTool()])
        }
    }
}
```

- [ ] **Step 2: Verify the file was created**

Open Xcode (Cmd+B). SourceKit may show "Cannot find type RunShellCommandTool" etc — these are expected false positives for types not yet created. As long as the build doesn't fail for THIS file in isolation, proceed.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/Tools/AgentTool.swift
git commit -m "feat(agents): add AgentTool protocol + ToolBox factory stub"
```

---

## Task 2: RunShellCommandTool

**Files:**
- Create: `TipTour/Agents/Tools/ShellTool.swift`

- [ ] **Step 1: Create the file**

```swift
// TipTour/Agents/Tools/ShellTool.swift

import Foundation

/// Runs a shell command using /bin/zsh and returns combined stdout + stderr.
/// Hard timeout of 30 seconds — the process is force-terminated if it exceeds this.
struct RunShellCommandTool: AgentTool {

    let name = "run_shell_command"

    let description = """
        Run a shell command using /bin/zsh. Returns combined stdout and stderr. \
        Commands time out after 30 seconds. Good for: file operations, git, curl, \
        open, osascript, brew, and other CLI tools. Avoid long-running processes.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to execute."
                },
                "working_directory": {
                    "type": "string",
                    "description": "Optional absolute path to run the command in. Defaults to the user home directory."
                }
            },
            "required": ["command"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(argumentsJSON)
            return await ShellRunner.run(
                command: args.command,
                workingDirectory: args.workingDirectory,
                timeoutSeconds: 30
            )
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Argument parsing

    private struct ParsedArgs {
        let command: String
        let workingDirectory: String?
    }

    private func parseArguments(_ json: String) throws -> ParsedArgs {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolArgumentError.malformedJSON
        }
        guard let command = dict["command"] as? String, !command.isEmpty else {
            throw ToolArgumentError.missingRequiredField("command")
        }
        let workingDirectory = dict["working_directory"] as? String
        return ParsedArgs(command: command, workingDirectory: workingDirectory)
    }
}

// MARK: - Process runner

/// Wraps Foundation.Process in async/await with a timeout race.
/// Uses @unchecked Sendable because the NSLock + terminationHandler pattern
/// is manually thread-safe but the compiler cannot verify it statically.
private final class ShellRunner: @unchecked Sendable {

    private let lock = NSLock()
    private var hasResumed = false
    private var continuation: CheckedContinuation<String, Never>?

    static func run(
        command: String,
        workingDirectory: String?,
        timeoutSeconds: TimeInterval
    ) async -> String {
        await withCheckedContinuation { continuation in
            let runner = ShellRunner()
            runner.continuation = continuation
            runner.start(command: command, workingDirectory: workingDirectory, timeout: timeoutSeconds)
        }
    }

    private func start(command: String, workingDirectory: String?, timeout: TimeInterval) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] finishedProcess in
            guard let self else { return }
            let stdout = String(
                data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            let exitCode = finishedProcess.terminationStatus
            let output = exitCode == 0 ? combined : "Exit code \(exitCode):\n\(combined)"
            self.resume(returning: output.isEmpty ? "(no output)" : output)
        }

        do {
            try process.run()
        } catch {
            resume(returning: "Error starting process: \(error.localizedDescription)")
            return
        }

        // Timeout: terminate and resume if the process runs too long.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            process.terminate()
            self.resume(returning: "Error: command timed out after \(Int(timeout)) seconds.")
        }
    }

    private func resume(returning value: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation?.resume(returning: value)
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

Expected: builds cleanly. SourceKit may show "RunShellCommandTool" underlined as unknown in AgentTool.swift — normal, resolves on indexing.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/Tools/ShellTool.swift
git commit -m "feat(agents): add RunShellCommandTool with 30s timeout"
```

---

## Task 3: FileTools

**Files:**
- Create: `TipTour/Agents/Tools/FileTools.swift`

- [ ] **Step 1: Create the file**

```swift
// TipTour/Agents/Tools/FileTools.swift

import Foundation

// MARK: - Read File

struct ReadFileTool: AgentTool {

    let name = "read_file"

    let description = """
        Read the text contents of a file at the given absolute path. \
        Returns up to 20,000 characters. If the file is larger, only the \
        first 20,000 characters are returned with a truncation notice.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute path to the file to read."
                }
            },
            "required": ["path"]
        }
        """

    private let characterLimit = 20_000

    func execute(argumentsJSON: String) async -> String {
        do {
            let path = try parsePath(from: argumentsJSON)
            let content = try String(contentsOfFile: path, encoding: .utf8)
            if content.count > characterLimit {
                let truncated = String(content.prefix(characterLimit))
                return "\(truncated)\n\n[Truncated — file has \(content.count) characters, showing first \(characterLimit)]"
            }
            return content
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }
    }

    private func parsePath(from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = dict["path"] as? String, !path.isEmpty else {
            throw ToolArgumentError.missingRequiredField("path")
        }
        return path
    }
}

// MARK: - Write File

struct WriteFileTool: AgentTool {

    let name = "write_file"

    let description = """
        Write text content to a file at the given absolute path. \
        Creates intermediate directories if they don't exist. \
        Overwrites any existing file at that path.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute path to the file to write."
                },
                "content": {
                    "type": "string",
                    "description": "The text content to write to the file."
                }
            },
            "required": ["path", "content"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            let url = URL(fileURLWithPath: args.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try args.content.write(to: url, atomically: true, encoding: .utf8)
            return "Successfully wrote \(args.content.count) characters to \(args.path)"
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }

    private struct ParsedArgs {
        let path: String
        let content: String
    }

    private func parseArguments(from json: String) throws -> ParsedArgs {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = dict["path"] as? String, !path.isEmpty,
              let content = dict["content"] as? String else {
            throw ToolArgumentError.missingRequiredField("path or content")
        }
        return ParsedArgs(path: path, content: content)
    }
}

// MARK: - List Directory

struct ListDirectoryTool: AgentTool {

    let name = "list_directory"

    let description = """
        List the contents of a directory at the given absolute path. \
        Returns file names, types (file/directory), and sizes. \
        Not recursive — lists only the immediate children.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute path to the directory to list."
                }
            },
            "required": ["path"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let path = try parsePath(from: argumentsJSON)
            let manager = FileManager.default
            let items = try manager.contentsOfDirectory(atPath: path)
            if items.isEmpty { return "Directory is empty: \(path)" }

            let lines: [String] = items.sorted().map { item in
                let fullPath = (path as NSString).appendingPathComponent(item)
                var isDirectory: ObjCBool = false
                manager.fileExists(atPath: fullPath, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    return "[dir]  \(item)/"
                } else {
                    let size = (try? manager.attributesOfItem(atPath: fullPath)[.size] as? Int) ?? 0
                    return "[file] \(item) (\(byteCountString(size)))"
                }
            }
            return "Contents of \(path):\n" + lines.joined(separator: "\n")
        } catch {
            return "Error listing directory: \(error.localizedDescription)"
        }
    }

    private func parsePath(from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = dict["path"] as? String, !path.isEmpty else {
            throw ToolArgumentError.missingRequiredField("path")
        }
        return path
    }

    private func byteCountString(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/Tools/FileTools.swift
git commit -m "feat(agents): add ReadFileTool, WriteFileTool, ListDirectoryTool"
```

---

## Task 4: WebTools

**Files:**
- Create: `TipTour/Agents/Tools/WebTools.swift`

- [ ] **Step 1: Create the file**

```swift
// TipTour/Agents/Tools/WebTools.swift

import Foundation

// MARK: - Web Fetch

/// Fetches the raw content of a URL via GET request and returns up to 10,000
/// characters of the response body as plain text (HTML tags stripped).
struct WebFetchTool: AgentTool {

    let name = "web_fetch"

    let description = """
        Fetch the content of a URL. Returns the first 10,000 characters of \
        the response body with HTML tags stripped. Use for reading web pages, \
        API responses, or any publicly accessible URL.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "The URL to fetch (must be http:// or https://)."
                }
            },
            "required": ["url"]
        }
        """

    private let characterLimit = 10_000

    func execute(argumentsJSON: String) async -> String {
        do {
            let urlString = try parseURL(from: argumentsJSON)
            guard let url = URL(string: urlString),
                  url.scheme == "http" || url.scheme == "https" else {
                return "Error: '\(urlString)' is not a valid http/https URL."
            }

            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) TipTourAgent/1.0",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode >= 400 {
                return "Error: HTTP \(httpResponse.statusCode) for \(urlString)"
            }

            let rawText = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? "(non-text response)"

            let plainText = stripHTMLTags(from: rawText)
            let trimmed = plainText
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            if trimmed.count > characterLimit {
                return String(trimmed.prefix(characterLimit))
                    + "\n\n[Truncated — showing first \(characterLimit) of \(trimmed.count) characters]"
            }
            return trimmed.isEmpty ? "(empty response)" : trimmed

        } catch {
            return "Error fetching URL: \(error.localizedDescription)"
        }
    }

    private func parseURL(from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = dict["url"] as? String, !urlString.isEmpty else {
            throw ToolArgumentError.missingRequiredField("url")
        }
        return urlString
    }

    /// Removes HTML/XML tags using a regex. Not a full HTML parser — good enough
    /// for extracting readable text from web pages.
    private func stripHTMLTags(from html: String) -> String {
        html.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
    }
}

// MARK: - Web Search (DuckDuckGo Instant Answer API)

/// Queries the DuckDuckGo Instant Answer API (no API key required).
/// Returns a summary and up to 5 related topics with titles and URLs.
struct WebSearchTool: AgentTool {

    let name = "web_search"

    let description = """
        Search the web using DuckDuckGo. Returns an abstract summary and \
        up to 5 related results with titles and URLs. For detailed page \
        content, follow up with web_fetch on a specific URL.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The search query."
                }
            },
            "required": ["query"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let query = try parseQuery(from: argumentsJSON)
            return await performSearch(query: query)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func parseQuery(from json: String) throws -> String {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = dict["query"] as? String, !query.isEmpty else {
            throw ToolArgumentError.missingRequiredField("query")
        }
        return query
    }

    private func performSearch(query: String) async -> String {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://api.duckduckgo.com/?q=\(encodedQuery)&format=json&no_html=1&skip_disambig=1"
        guard let url = URL(string: urlString) else {
            return "Error: could not construct search URL."
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("TipTourAgent/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Error: unexpected search API response format."
            }

            var output: [String] = []

            if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
                output.append("Summary: \(abstract)")
                if let source = json["AbstractURL"] as? String, !source.isEmpty {
                    output.append("Source: \(source)")
                }
            }

            if let topics = json["RelatedTopics"] as? [[String: Any]] {
                let topResults = topics.prefix(5).compactMap { topic -> String? in
                    guard let text = topic["Text"] as? String, !text.isEmpty else { return nil }
                    let firstURL = topic["FirstURL"] as? String ?? ""
                    return "• \(text)" + (firstURL.isEmpty ? "" : "\n  \(firstURL)")
                }
                if !topResults.isEmpty {
                    output.append("\nRelated results:")
                    output.append(contentsOf: topResults)
                }
            }

            return output.isEmpty
                ? "No results found for '\(query)'. Try rephrasing or use web_fetch with a specific URL."
                : output.joined(separator: "\n")

        } catch {
            return "Error searching: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/Tools/WebTools.swift
git commit -m "feat(agents): add WebFetchTool and WebSearchTool (DuckDuckGo)"
```

---

## Task 5: MacControlTools

**Files:**
- Create: `TipTour/Agents/Tools/MacControlTools.swift`

These tools read macOS accessibility trees and click UI elements. They bridge to the existing `AccessibilityTreeResolver` and `ActionExecutor` (@MainActor) classes.

- [ ] **Step 1: Create the file**

```swift
// TipTour/Agents/Tools/MacControlTools.swift

import AppKit
import Foundation

// MARK: - Read AX Tree

/// Returns a compact set-of-marks listing from the frontmost app's accessibility tree.
/// The output lists interactive elements by role + label, which the agent can reference
/// by label in a follow-up ClickElementTool call.
struct ReadAXTreeTool: AgentTool {

    let name = "read_ax_tree"

    let description = """
        Read the accessibility tree of the currently frontmost macOS app. \
        Returns a list of interactive elements (buttons, text fields, menus, etc.) \
        with their labels. Use these labels with click_element to interact with the UI.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "app_hint": {
                    "type": "string",
                    "description": "Optional app name or bundle ID hint (e.g. 'Safari', 'com.apple.safari'). Defaults to the frontmost app."
                }
            },
            "required": []
        }
        """

    func execute(argumentsJSON: String) async -> String {
        guard AccessibilityTreeResolver.isPermissionGranted else {
            return "Error: TipTour does not have Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility."
        }

        let appHint = parseAppHint(from: argumentsJSON)

        let resolver = AccessibilityTreeResolver()
        guard let marks = resolver.setOfMarksForTargetApp(hint: appHint) else {
            return "No accessibility elements found for the current app. The app may not expose accessibility data."
        }

        let formatted = AccessibilityTreeResolver.formatMarks(marks)
        return "Accessibility elements:\n\(formatted)"
    }

    private func parseAppHint(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict["app_hint"] as? String
    }
}

// MARK: - Click Element

/// Resolves a UI element by label using the macOS accessibility tree,
/// then clicks its center point using ActionExecutor (which posts CGEvents at HID level).
struct ClickElementTool: AgentTool {

    let name = "click_element"

    let description = """
        Click a UI element in the frontmost macOS app by its accessibility label. \
        Use read_ax_tree first to get the exact label string. \
        TipTour must have Accessibility permission for this to work.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "label": {
                    "type": "string",
                    "description": "The exact accessibility label of the element to click (from read_ax_tree output)."
                },
                "app_hint": {
                    "type": "string",
                    "description": "Optional app name hint to narrow the search (e.g. 'Safari')."
                }
            },
            "required": ["label"]
        }
        """

    func execute(argumentsJSON: String) async -> String {
        do {
            let args = try parseArguments(from: argumentsJSON)
            return try await performClick(label: args.label, appHint: args.appHint)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func performClick(label: String, appHint: String?) async throws -> String {
        guard AccessibilityTreeResolver.isPermissionGranted else {
            throw ClickToolError.noAccessibilityPermission
        }

        // AX resolution + ActionExecutor.shared both require MainActor.
        return try await MainActor.run {
            let resolver = AccessibilityTreeResolver()
            guard let element = resolver.findElement(byLabel: label, targetAppHint: appHint) else {
                throw ClickToolError.elementNotFound(label)
            }

            // ActionExecutor.shared is @MainActor — safe to access here.
            // click is async, so we need to return a Task from within the MainActor context
            // and await it outside. We use the pattern below because MainActor.run supports
            // async closures.
            try await ActionExecutor.shared.click(
                atGlobalScreenPoint: element.center,
                activatingTargetApp: nil
            )

            return "Clicked '\(label)' at (\(Int(element.center.x)), \(Int(element.center.y)))"
        }
    }

    private struct ParsedArgs {
        let label: String
        let appHint: String?
    }

    private func parseArguments(from json: String) throws -> ParsedArgs {
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let label = dict["label"] as? String, !label.isEmpty else {
            throw ToolArgumentError.missingRequiredField("label")
        }
        return ParsedArgs(label: label, appHint: dict["app_hint"] as? String)
    }
}

// MARK: - Click errors

private enum ClickToolError: Error, LocalizedError {
    case elementNotFound(String)
    case noAccessibilityPermission

    var errorDescription: String? {
        switch self {
        case .elementNotFound(let label):
            return "No element with label '\(label)' found in the accessibility tree. Run read_ax_tree to see available elements."
        case .noAccessibilityPermission:
            return "TipTour does not have Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility."
        }
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

Expected: clean build. `AppKit` import is required for `NSRunningApplication` type used indirectly via ActionExecutor.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/Tools/MacControlTools.swift
git commit -m "feat(agents): add ReadAXTreeTool and ClickElementTool"
```

---

## Task 6: SpawnClaudeCodeTool

**Files:**
- Create: `TipTour/Agents/Tools/SpawnClaudeCodeTool.swift`

- [ ] **Step 1: Create the file**

```swift
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
            let claudePath = resolveClaudePath()
            guard let claudePath else {
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
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Agents/Tools/SpawnClaudeCodeTool.swift
git commit -m "feat(agents): add SpawnClaudeCodeTool (claude --print subprocess)"
```

---

## Task 7: Wire ToolBox into TaskAgent + AgentSwarmManager

**Files:**
- Modify: `TipTour/Agents/Swarm/TaskAgent.swift` (lines 13, 43–54, 202–208)
- Modify: `TipTour/Agents/Swarm/AgentSwarmManager.swift` (lines 31–38)

- [ ] **Step 1: Update TaskAgent.swift — add `toolBox` property and update init**

In `TaskAgent.swift`, add `let toolBox: ToolBox` after line 13 (`let swarmManager: AgentSwarmManager`):

Replace this block (lines 13–54):
```swift
    let provider: (any LLMProvider)?
    let swarmManager: AgentSwarmManager

    private var conversationHistory: [LLMMessage] = []
    private var interruptQueue: [String] = []
    private(set) var state: AgentState = .spawning
    private(set) var currentStep: String = "Preparing..."
    private(set) var stepHistory: [AgentStep] = []
    private(set) var tokensUsed: Int = 0
    private let startedAt: Date = Date()
    private var chatHistory: [AgentChatMessage] = []

    ...

    init(
        taskDescription: String,
        taskType: TaskType,
        provider: (any LLMProvider)?,
        swarmManager: AgentSwarmManager
    ) {
        self.id = UUID()
        self.taskDescription = taskDescription
        self.taskType = taskType
        self.provider = provider
        self.swarmManager = swarmManager
    }
```

With:
```swift
    let provider: (any LLMProvider)?
    let swarmManager: AgentSwarmManager
    let toolBox: ToolBox

    private var conversationHistory: [LLMMessage] = []
    private var interruptQueue: [String] = []
    private(set) var state: AgentState = .spawning
    private(set) var currentStep: String = "Preparing..."
    private(set) var stepHistory: [AgentStep] = []
    private(set) var tokensUsed: Int = 0
    private let startedAt: Date = Date()
    private var chatHistory: [AgentChatMessage] = []

    ...

    init(
        taskDescription: String,
        taskType: TaskType,
        provider: (any LLMProvider)?,
        swarmManager: AgentSwarmManager,
        toolBox: ToolBox = ToolBox()
    ) {
        self.id = UUID()
        self.taskDescription = taskDescription
        self.taskType = taskType
        self.provider = provider
        self.swarmManager = swarmManager
        self.toolBox = toolBox
    }
```

- [ ] **Step 2: Replace the two stub methods in TaskAgent.swift**

Replace lines 202–208 (the two stub methods):
```swift
    private func availableToolDefinitions() -> [LLMTool] {
        []
    }

    private func dispatchToolCall(_ toolCall: LLMToolCall) async -> String {
        "Tool '\(toolCall.name)' is not yet implemented. Phase 2 adds real tools."
    }
```

With:
```swift
    private func availableToolDefinitions() -> [LLMTool] {
        toolBox.definitions
    }

    private func dispatchToolCall(_ toolCall: LLMToolCall) async -> String {
        await toolBox.execute(toolCall: toolCall)
    }
```

- [ ] **Step 3: Update AgentSwarmManager.swift — build ToolBox at spawn**

In `AgentSwarmManager.swift`, update the `spawn` method body (lines 31–38) to build and pass a `ToolBox`:

Replace:
```swift
        let newAgent = TaskAgent(
            taskDescription: taskDescription,
            taskType: taskType,
            provider: provider,
            swarmManager: self
        )
```

With:
```swift
        let toolBox = ToolBox.build(for: taskType)
        let newAgent = TaskAgent(
            taskDescription: taskDescription,
            taskType: taskType,
            provider: provider,
            swarmManager: self,
            toolBox: toolBox
        )
```

- [ ] **Step 4: Build in Xcode (Cmd+B)**

Expected: clean build. All the stub false-positive errors from Phase 1 now resolve to real implementations.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Swarm/TaskAgent.swift TipTour/Agents/Swarm/AgentSwarmManager.swift
git commit -m "feat(agents): wire ToolBox into TaskAgent and AgentSwarmManager"
```

---

## Task 8: Tests + CLAUDE.md Update

**Files:**
- Create: `TipTourTests/AgentToolTests.swift`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Create AgentToolTests.swift**

```swift
// TipTourTests/AgentToolTests.swift

import Foundation
import Testing
@testable import TipTour

// MARK: - ToolBox tests

@Suite("ToolBox")
struct ToolBoxTests {

    @Test func buildReturnsNonEmptyToolsForAllTaskTypes() {
        for taskType in TaskType.allCases {
            let toolBox = ToolBox.build(for: taskType)
            #expect(!toolBox.definitions.isEmpty, "Expected tools for task type \(taskType.rawValue)")
        }
    }

    @Test func definitionsMatchProtocolNames() {
        let toolBox = ToolBox.build(for: .coding)
        for definition in toolBox.definitions {
            #expect(!definition.name.isEmpty)
            #expect(!definition.description.isEmpty)
            #expect(!definition.parametersJSON.isEmpty)
        }
    }

    @Test func returnsErrorStringForUnknownToolCall() async {
        let toolBox = ToolBox.build(for: .coding)
        let fakeCall = LLMToolCall(id: "x", name: "nonexistent_tool", argumentsJSON: "{}")
        let result = await toolBox.execute(toolCall: fakeCall)
        #expect(result.contains("Error"))
        #expect(result.contains("nonexistent_tool"))
    }

    @Test func parametersJSONIsValidForAllTools() {
        for taskType in TaskType.allCases {
            let toolBox = ToolBox.build(for: taskType)
            for definition in toolBox.definitions {
                guard let data = definition.parametersJSON.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    Issue.record("Invalid parametersJSON for tool '\(definition.name)' in task type '\(taskType.rawValue)'")
                    return
                }
            }
        }
    }
}

// MARK: - RunShellCommandTool tests

@Suite("RunShellCommandTool")
struct RunShellCommandToolTests {

    @Test func echoCommandReturnsOutput() async {
        let tool = RunShellCommandTool()
        let result = await tool.execute(argumentsJSON: #"{"command": "echo hello"}"#)
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test func nonZeroExitCodeIncludesExitCodeInOutput() async {
        let tool = RunShellCommandTool()
        let result = await tool.execute(argumentsJSON: #"{"command": "exit 42"}"#)
        #expect(result.contains("42"))
    }

    @Test func missingCommandFieldReturnsError() async {
        let tool = RunShellCommandTool()
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }

    @Test func malformedJSONReturnsError() async {
        let tool = RunShellCommandTool()
        let result = await tool.execute(argumentsJSON: "not json")
        #expect(result.contains("Error"))
    }

    @Test func workingDirectoryIsApplied() async {
        let tool = RunShellCommandTool()
        let tmpDir = NSTemporaryDirectory()
        let json = #"{"command": "pwd", "working_directory": "\#(tmpDir.dropLast())"}"#
        let result = await tool.execute(argumentsJSON: json)
        // pwd output should be or start with the tmp dir path.
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"))
    }
}

// MARK: - FileTools tests

@Suite("FileTools")
struct FileToolsTests {

    @Test func readFileToolReadsExistingFile() async throws {
        let tmp = NSTemporaryDirectory() + "tiptour_test_read_\(UUID()).txt"
        let content = "Hello from read file test"
        try content.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let tool = ReadFileTool()
        let result = await tool.execute(argumentsJSON: #"{"path": "\#(tmp)"}"#)
        #expect(result == content)
    }

    @Test func readFileToolReturnsErrorForMissingFile() async {
        let tool = ReadFileTool()
        let result = await tool.execute(argumentsJSON: #"{"path": "/nonexistent/path/file.txt"}"#)
        #expect(result.contains("Error"))
    }

    @Test func writeFileThenReadRoundTrips() async throws {
        let tmp = NSTemporaryDirectory() + "tiptour_test_write_\(UUID()).txt"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let content = "Round trip test content"
        let writeTool = WriteFileTool()
        let writeResult = await writeTool.execute(
            argumentsJSON: #"{"path": "\#(tmp)", "content": "\#(content)"}"#
        )
        #expect(writeResult.contains("Successfully"))

        let readTool = ReadFileTool()
        let readResult = await readTool.execute(argumentsJSON: #"{"path": "\#(tmp)"}"#)
        #expect(readResult == content)
    }

    @Test func listDirectoryToolListsContents() async throws {
        let tool = ListDirectoryTool()
        let result = await tool.execute(argumentsJSON: #"{"path": "/tmp"}"#)
        // /tmp always exists and has at least one item on macOS.
        #expect(!result.contains("Error"))
    }

    @Test func listDirectoryToolReturnsErrorForMissingDirectory() async {
        let tool = ListDirectoryTool()
        let result = await tool.execute(argumentsJSON: #"{"path": "/nonexistent/dir"}"#)
        #expect(result.contains("Error"))
    }
}

// MARK: - WebTools tests (offline — just validates structure)

@Suite("WebTools")
struct WebToolsTests {

    @Test func webFetchToolParametersJSONIsValidJSON() {
        let tool = WebFetchTool()
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func webSearchToolParametersJSONIsValidJSON() {
        let tool = WebSearchTool()
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func webFetchToolReturnsErrorForInvalidURL() async {
        let tool = WebFetchTool()
        let result = await tool.execute(argumentsJSON: #"{"url": "not-a-url"}"#)
        #expect(result.contains("Error"))
    }

    @Test func webFetchToolReturnsErrorForMissingURLField() async {
        let tool = WebFetchTool()
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }
}

// MARK: - MacControlTools tests (structure only — real AX requires permission + running app)

@Suite("MacControlTools")
struct MacControlToolsTests {

    @Test func readAXTreeToolParametersJSONIsValidJSON() {
        let tool = ReadAXTreeTool()
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func clickElementToolReturnsErrorForMissingLabel() async {
        let tool = ClickElementTool()
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }

    @Test func clickElementToolReturnsErrorForMalformedJSON() async {
        let tool = ClickElementTool()
        let result = await tool.execute(argumentsJSON: "bad json")
        #expect(result.contains("Error"))
    }
}

// MARK: - SpawnClaudeCodeTool tests

@Suite("SpawnClaudeCodeTool")
struct SpawnClaudeCodeToolTests {

    @Test func parametersJSONIsValidJSON() {
        let tool = SpawnClaudeCodeTool()
        guard let data = tool.parametersJSON.data(using: .utf8) else {
            Issue.record("parametersJSON is not UTF-8")
            return
        }
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test func returnsErrorForMissingTaskField() async {
        let tool = SpawnClaudeCodeTool()
        let result = await tool.execute(argumentsJSON: #"{}"#)
        #expect(result.contains("Error"))
    }
}

// MARK: - TaskAgent + ToolBox integration

@Suite("TaskAgentToolIntegration")
struct TaskAgentToolIntegrationTests {

    @Test func taskAgentWithToolBoxDispatchesToolCallSuccessfully() async {
        // The mock provider returns a tool call, which the agent dispatches,
        // then the next mock response returns plain text to complete the loop.
        let swarm = AgentSwarmManager()
        let mockProvider = MockLLMProvider(id: "tool-integration-test")

        // First call: return a tool call for run_shell_command.
        // Second call: return text to complete.
        var callCount = 0
        mockProvider.responseFactory = {
            callCount += 1
            if callCount == 1 {
                return .toolCalls([
                    LLMToolCall(id: "call-1", name: "run_shell_command", argumentsJSON: #"{"command":"echo success"}"#)
                ])
            }
            return .text("Task complete.")
        }

        let toolBox = ToolBox.build(for: .fileManagement)
        let agent = TaskAgent(
            taskDescription: "Echo a test string",
            taskType: .fileManagement,
            provider: mockProvider,
            swarmManager: swarm,
            toolBox: toolBox
        )

        await agent.run()

        let status = await agent.currentStatus
        #expect(status.state == .completed)
        // At least 2 steps: tool dispatch + completion.
        #expect(status.stepHistory.count >= 2)
    }
}
```

- [ ] **Step 2: Update MockLLMProvider in AgentSwarmTests.swift to support responseFactory**

The integration test above uses `mockProvider.responseFactory`. Update `MockLLMProvider` in `TipTourTests/AgentSwarmTests.swift` to support it:

Replace the existing `MockLLMProvider` (lines 10–28):
```swift
final class MockLLMProvider: LLMProvider {
    let providerId: String
    let displayName: String
    let supportsVoice = false
    let costTier: LLMCostTier = .low

    var responseToReturn: LLMResponse = .text("mock response")
    var shouldThrow = false
    /// When set, overrides responseToReturn — called once per complete() invocation.
    var responseFactory: (() -> LLMResponse)?

    init(id: String) {
        self.providerId = id
        self.displayName = "Mock (\(id))"
    }

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        if shouldThrow { throw LLMProviderError.missingAPIKey(providerName: "Mock") }
        return responseFactory?() ?? responseToReturn
    }
}
```

- [ ] **Step 3: Run tests in Xcode (Cmd+U)**

Expected: all tests pass. The `taskAgentWithToolBoxDispatchesToolCallSuccessfully` test runs a real shell command (`echo success`) via the tool dispatch path.

- [ ] **Step 4: Update CLAUDE.md — add new tool files to Key Files table**

In the Key Files table, add these rows after the existing `TipTour/Agents/Swarm/TaskAgent.swift` row:

```
| `TipTour/Agents/Tools/AgentTool.swift` | ~100 | `AgentTool` protocol, `ToolBox` factory struct, `ToolArgumentError`. |
| `TipTour/Agents/Tools/ShellTool.swift` | ~100 | `RunShellCommandTool` — /bin/zsh subprocess with 30s timeout. |
| `TipTour/Agents/Tools/FileTools.swift` | ~110 | `ReadFileTool`, `WriteFileTool`, `ListDirectoryTool`. |
| `TipTour/Agents/Tools/WebTools.swift` | ~130 | `WebFetchTool` (URLSession GET), `WebSearchTool` (DuckDuckGo Instant API). |
| `TipTour/Agents/Tools/MacControlTools.swift` | ~120 | `ReadAXTreeTool` (AX tree dump), `ClickElementTool` (AX + ActionExecutor). |
| `TipTour/Agents/Tools/SpawnClaudeCodeTool.swift` | ~75 | `SpawnClaudeCodeTool` — spawns `claude --print` subprocess. |
```

Also update line count estimates for modified files:
- `TipTour/Agents/Swarm/TaskAgent.swift`: `~195` → `~200`
- `TipTour/Agents/Swarm/AgentSwarmManager.swift`: `~145` → `~148`

- [ ] **Step 5: Commit**

```bash
git add TipTourTests/AgentToolTests.swift TipTourTests/AgentSwarmTests.swift CLAUDE.md
git commit -m "feat(agents): add tool tests and update CLAUDE.md for Phase 2"
```

---

## Self-Review

**Spec coverage check:**

| Requirement | Covered by task |
|-------------|----------------|
| `AgentTool` protocol + `ToolInput`/`ToolOutput` | Task 1 (using `argumentsJSON: String` / `-> String` directly — simpler than wrapper types, same semantics) |
| `ToolBox` factory by task type | Task 1 |
| `RunShellCommandTool` | Task 2 |
| `ReadFileTool`, `WriteFileTool`, `ListDirectoryTool` | Task 3 |
| `WebSearchTool`, `WebFetchTool` | Task 4 |
| `ReadAXTreeTool`, `ClickElementTool` | Task 5 |
| `SpawnClaudeCodeTool` | Task 6 |
| Wire into TaskAgent (replace stubs) | Task 7 |
| Wire into AgentSwarmManager (pass ToolBox at spawn) | Task 7 |
| Tests | Task 8 |
| CLAUDE.md update | Task 8 |

**Placeholder scan:** No TBDs, TODOs, or vague requirements found.

**Type consistency check:**
- `ToolBox.execute(toolCall: LLMToolCall)` matches `TaskAgent.dispatchToolCall(_ toolCall: LLMToolCall)` usage ✓
- `ToolBox.definitions` returns `[LLMTool]` matching `availableToolDefinitions() -> [LLMTool]` ✓
- `AgentTool.execute(argumentsJSON: String) async -> String` (non-throwing) — each tool catches internally ✓
- `ShellRunner` referenced in both `ShellTool.swift` (RunShellCommandTool) and `SpawnClaudeCodeTool.swift` — both files need `ShellRunner` accessible. Since `ShellRunner` is `private` in `ShellTool.swift`, `SpawnClaudeCodeTool` won't see it. **Fix:** move `ShellRunner` to its own file or make it `internal`. Best: declare `ShellRunner` as `internal` (remove `private`) in `ShellTool.swift` so both tools can use it. `SpawnClaudeCodeTool` imports nothing extra — both are in the same module (TipTour).

**Fix for type consistency issue above:** In `ShellTool.swift`, change `private final class ShellRunner` → `final class ShellRunner`. No other changes needed since both files are in the TipTour module.

- `MockLLMProvider.responseFactory` added in Task 8 Step 2 — used in `TaskAgentToolIntegrationTests` ✓
- `LLMToolCall(id:name:argumentsJSON:)` memberwise initializer — `LLMToolCall` is a struct in `LLMProvider.swift` with these exact properties ✓
