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
