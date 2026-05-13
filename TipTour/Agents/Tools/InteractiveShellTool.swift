// TipTour/Agents/Tools/InteractiveShellTool.swift

import Foundation

// MARK: - Interactive shell session

/// One long-running `/bin/zsh -i` subprocess that the agent can drive
/// across many tool calls. Working directory, exported env vars, and
/// shell history persist between calls — unlike `RunShellCommandTool`,
/// which spawns a fresh shell per command and forgets `cd` and `export`.
///
/// Each `TaskAgent` owns its own `InteractiveShellSession` (lazily
/// initialized on first call). When the agent terminates, the session's
/// `shutdown()` is called to kill the subprocess and free file
/// descriptors. Shared across the agent's tool calls but never across
/// agents — two agents using `interactive_shell` get independent shells.
///
/// **Not a real PTY.** We use Foundation `Process` with pipes, which
/// works for non-interactive commands (build, git, grep, brew, etc.)
/// but won't render full-screen TUI apps (vim, top, less without -F).
/// Building a true PTY would need `posix_openpt` + fork/exec dance
/// that's an order of magnitude more code; for an agent's needs, the
/// pipe-based approach is sufficient and far simpler to keep correct.
///
/// **Concurrency model:** the session is an actor so concurrent calls
/// from the same agent (rare — agents serialize their tool dispatch)
/// are queued cleanly without interleaving stdin writes.
actor InteractiveShellSession {

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Working directory the shell starts in. Set at init time so the
    /// agent's workspace is the default cwd for every command.
    private let initialWorkingDirectory: URL?

    /// Stable, command-unique sentinel: emitted after each command so
    /// we can tell where its output ends. Includes a UUID to avoid
    /// accidental matches in command output. Bumped per session, not
    /// per command — one UUID per session is plenty.
    private let sentinel: String

    init(initialWorkingDirectory: URL? = nil) {
        self.initialWorkingDirectory = initialWorkingDirectory
        self.sentinel = "__TIPTOUR_SHELL_DONE_\(UUID().uuidString)__"
    }

    deinit {
        // Best-effort cleanup if the holder forgot to call shutdown().
        // Process.terminate is safe to call from any thread.
        process?.terminate()
    }

    // MARK: - Lifecycle

    /// Start the shell if not already running. Returns true if the
    /// shell is healthy (running) after this call.
    private func startIfNeeded() -> Bool {
        if let existing = process, existing.isRunning { return true }

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-i` for interactive (so PS1/PS2 are set and shell init runs).
        // `-s` reads commands from stdin, which is what we drive.
        newProcess.arguments = ["-is"]

        if let workDir = initialWorkingDirectory {
            newProcess.currentDirectoryURL = workDir
        }

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        newProcess.standardInput = stdin
        newProcess.standardOutput = stdout
        newProcess.standardError = stderr

        // Set PATH and TERM so common tools work. Without TERM, many
        // CLIs (git, less) print "TERM environment variable not set"
        // errors. `dumb` is the safest choice for non-PTY shells.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        // Make zsh prompts machine-friendly — empty PS1/PS2 means we
        // don't have to filter prompt strings out of command output.
        env["PS1"] = ""
        env["PS2"] = ""
        env["PROMPT"] = ""
        env["RPROMPT"] = ""
        newProcess.environment = env

        do {
            try newProcess.run()
        } catch {
            print("[InteractiveShellSession] failed to start /bin/zsh: \(error.localizedDescription)")
            return false
        }

        self.process = newProcess
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        return true
    }

    /// Terminate the underlying subprocess. Called when the owning
    /// agent ends so we don't leak shells.
    func shutdown() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    // MARK: - Run a command

    /// Execute `command` in the persistent shell. The output is
    /// captured until we see the per-session sentinel echoed back.
    /// Returns combined stdout + stderr text or an error message.
    func runCommand(_ command: String, timeoutSeconds: TimeInterval) async -> String {
        if Task.isCancelled {
            return "Error: shell command cancelled before launch."
        }
        guard startIfNeeded(), let stdin = stdinPipe, let stdout = stdoutPipe else {
            return "Error: could not start /bin/zsh."
        }

        let outputTerminator = sentinel
        // We append `echo {sentinel}` so the read-loop has a clear
        // signal to stop. We also `echo {sentinel}` to stderr so we
        // can drain stderr without blocking when there's nothing there
        // (an alternative would be to merge 2>&1; we chose two
        // separate streams so the agent can attribute warnings to
        // stderr vs real output).
        let combined = "\(command)\necho \(outputTerminator)\necho \(outputTerminator) 1>&2\n"
        guard let stdinData = combined.data(using: .utf8) else {
            return "Error: command contained non-UTF8 bytes."
        }

        do {
            try stdin.fileHandleForWriting.write(contentsOf: stdinData)
        } catch {
            return "Error: write to shell failed (\(error.localizedDescription))."
        }

        // Read stdout + stderr concurrently, race against a timeout.
        let outputText = await withTaskGroup(of: String?.self) { group -> String in
            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderrPipe?.fileHandleForReading
            let terminator = outputTerminator
            let timeoutNanoseconds = UInt64(timeoutSeconds * 1_000_000_000)

            group.addTask {
                return Self.readUntilSentinel(handle: stdoutHandle, sentinel: terminator)
            }
            if let stderrHandle {
                group.addTask {
                    return Self.readUntilSentinel(handle: stderrHandle, sentinel: terminator)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil // nil → timeout sentinel
            }

            var combinedText = ""
            var streamsCollected = 0
            let expectedStreams = stderrHandle == nil ? 1 : 2
            for await piece in group {
                if let piece {
                    if !piece.isEmpty { combinedText += piece }
                    streamsCollected += 1
                    if streamsCollected >= expectedStreams {
                        group.cancelAll()
                        break
                    }
                } else {
                    // Timeout fired.
                    group.cancelAll()
                    return combinedText.isEmpty
                        ? "Error: shell command timed out after \(Int(timeoutSeconds))s with no output."
                        : combinedText + "\n[Truncated — command timed out after \(Int(timeoutSeconds))s]"
                }
            }
            return combinedText
        }

        if outputText.isEmpty {
            return "(no output)"
        }
        return outputText
    }

    // MARK: - Streaming reader

    /// Drain a file handle until a line containing `sentinel` appears,
    /// then return everything read up to (but not including) that line.
    /// Synchronous because Foundation FileHandle reads block on no-data;
    /// we wrap the call in a Task in `runCommand` so the actor isn't
    /// stuck if the shell hangs.
    private static func readUntilSentinel(handle: FileHandle, sentinel: String) -> String {
        var buffer = ""
        while !Task.isCancelled {
            // 4KB chunks balance latency (small enough to flush often)
            // against syscall overhead.
            let chunk = handle.availableData
            if chunk.isEmpty {
                // Shell closed the pipe — give up.
                return buffer
            }
            if let piece = String(data: chunk, encoding: .utf8) {
                buffer.append(piece)
            }
            // Once the sentinel appears on a line of its own, trim
            // everything from that line onward (the sentinel line and
            // anything after) and return.
            if let range = buffer.range(of: "\n\(sentinel)\n") ?? buffer.range(of: "\(sentinel)\n") {
                return String(buffer[buffer.startIndex..<range.lowerBound])
            }
        }
        return buffer
    }
}

// MARK: - Tool wrapper

/// Agent-facing wrapper around `InteractiveShellSession`. Each agent
/// holds one tool instance, which holds one shell session.
///
/// The tool is reused across calls — that's the whole point. Working
/// directory changes (`cd`), exported env vars (`export PATH=...`),
/// shell aliases, and command history all persist between
/// `interactive_shell` tool calls within the same agent run.
struct InteractiveShellTool: AgentTool {

    let name = "interactive_shell"

    let description = """
        Run a shell command in a persistent /bin/zsh session. Unlike \
        run_shell_command (which spawns a fresh shell each time and \
        forgets state), this tool keeps the same shell across calls — \
        so `cd path/to/dir` in one call affects the next, exported env \
        vars stick, and you can chain dependent commands cleanly. \
        Default working directory is the agent's per-task workspace at \
        ~/Library/Application Support/TipTour/agent-workspaces/<id>/. \
        Commands time out after 60 seconds.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to run. Multi-line commands work via embedded newlines."
                }
            },
            "required": ["command"]
        }
        """

    private let session: InteractiveShellSession

    init(session: InteractiveShellSession) {
        self.session = session
    }

    func execute(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = dict["command"] as? String, !command.isEmpty else {
            return "Error: missing required argument 'command'."
        }
        return await session.runCommand(command, timeoutSeconds: 60)
    }
}
