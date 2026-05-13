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
final class ShellRunner: @unchecked Sendable {

    private let lock = NSLock()
    private var hasResumed = false
    private var continuation: CheckedContinuation<String, Never>?

    static func run(
        command: String,
        workingDirectory: String?,
        timeoutSeconds: TimeInterval
    ) async -> String {
        // Bail immediately if the agent has already been cancelled —
        // no point spawning a process whose output we'll throw away.
        if Task.isCancelled {
            return "Error: command cancelled before launch."
        }

        let runner = ShellRunner()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                runner.continuation = continuation
                runner.start(
                    command: command,
                    workingDirectory: workingDirectory,
                    timeout: timeoutSeconds
                )
            }
        } onCancel: {
            // Fires on whichever thread the cancellation propagates from.
            // `cancelRunningProcess` is internally lock-guarded so it's
            // safe to call from outside the actor that owns the runner.
            runner.cancelRunningProcess()
        }
    }

    /// Terminate the running process and resume the awaiting continuation
    /// with a cancellation message. Safe to call from any thread.
    func cancelRunningProcess() {
        lock.lock()
        let runningProcess = currentProcess
        lock.unlock()
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
        }
        resume(returning: "Error: command cancelled by agent termination.")
    }

    private var currentProcess: Process?

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

        // Stash the process so cancellation can terminate it. Reads
        // through the same lock that guards `hasResumed`.
        lock.lock()
        self.currentProcess = process
        lock.unlock()

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
