// TipTour/Agents/Swarm/TaskAgent.swift

import Foundation

/// A single background agent. Owns its LLM conversation history and runs
/// an agentic loop: call LLM → execute tool → check interrupts → repeat.
actor TaskAgent: Identifiable {

    let id: UUID
    let taskDescription: String
    let taskType: TaskType
    let provider: (any LLMProvider)?
    let swarmManager: AgentSwarmManager
    let toolBox: ToolBox

    private var conversationHistory: [LLMMessage] = []
    private var interruptQueue: [String] = []
    private(set) var state: AgentState = .spawning
    private(set) var currentStep: String = "Preparing..."
    private(set) var stepHistory: [AgentStep] = []
    private(set) var tokensUsed: Int = 0
    private(set) var toolCallCount: Int = 0
    private(set) var backtrackCount: Int = 0
    private let startedAt: Date = Date()
    private var chatHistory: [AgentChatMessage] = []
    private let skillHistoryBuffer: ToolCallHistoryBuffer
    /// The on-disk slug used by `autoSaveSkill` for this run. Captured
    /// AFTER `SkillLibraryStore.write` deduplicates, so EfficiencyMonitor's
    /// self-critique rewrite lands on the exact file we wrote rather than
    /// clobbering a sibling skill that happened to grab the base slug.
    private var autoSavedSkillSlugForThisRun: String?
    /// Per-agent shell session. Lazily started on the first
    /// `interactive_shell` tool call; torn down by
    /// `markTerminated` / `handleCancellation`.
    private let interactiveShellSession: InteractiveShellSession
    /// Number of times we've forced a re-prompt because the agent
    /// answered text-only on a tool-mandatory task. Capped so a
    /// genuinely-uncooperative model doesn't loop forever.
    private var textOnlyRedirectCount: Int = 0
    /// Max re-prompts before we accept a text-only answer. Bumped
    /// from 2 → 4 because gemini-2.5-flash sometimes needs more than
    /// one nudge before it stops apologising and actually calls a tool.
    /// Four redirects = up to 5 LLM calls total — still well under the
    /// 50-turn cap, but enough headroom to break through a stubborn
    /// model.
    private let maximumTextOnlyRedirects: Int = 4
    /// Per-agent workspace directory. The interactive shell starts
    /// here; tools that write files default to this directory unless
    /// the agent specifies an absolute path. Nil only if Application
    /// Support is unwritable (extremely rare).
    private let workspaceURL: URL?

    var currentStatus: AgentStatus {
        AgentStatus(
            id: id,
            agentName: taskType.displayName,
            taskSummary: taskDescription,
            state: state,
            currentStep: currentStep,
            stepHistory: stepHistory,
            tokensUsed: tokensUsed,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            blocker: state.currentBlocker,
            result: nil,
            isExpanded: false,
            isMinimised: false,
            chatHistory: chatHistory
        )
    }

    init(
        taskDescription: String,
        taskType: TaskType,
        provider: (any LLMProvider)?,
        swarmManager: AgentSwarmManager
    ) {
        let newId = UUID()
        self.id = newId
        self.taskDescription = taskDescription
        self.taskType = taskType
        self.provider = provider
        self.swarmManager = swarmManager
        let buffer = ToolCallHistoryBuffer()
        self.skillHistoryBuffer = buffer

        // Per-agent workspace under Application Support so the
        // interactive shell's default cwd is an isolated playground.
        // Two agents working on the file system never collide; the
        // workspace persists across tool calls but is cleaned up when
        // the agent terminates.
        let workspaceURL = Self.createWorkspace(forAgentId: newId)
        self.workspaceURL = workspaceURL
        let shellSession = InteractiveShellSession(initialWorkingDirectory: workspaceURL)
        self.interactiveShellSession = shellSession

        self.toolBox = ToolBox.build(
            for: taskType,
            historyBuffer: buffer,
            interactiveShellSession: shellSession,
            workspaceURL: workspaceURL
        )
    }

    /// Create the agent's workspace directory. Returns nil only if
    /// FileManager refuses to create it (very rare).
    private static func createWorkspace(forAgentId agentId: UUID) -> URL? {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let appSupport else { return nil }
        let workspaceRoot = appSupport
            .appendingPathComponent("TipTour", isDirectory: true)
            .appendingPathComponent("agent-workspaces", isDirectory: true)
            .appendingPathComponent(agentId.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workspaceRoot,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return workspaceRoot
        } catch {
            print("[TaskAgent] failed to create workspace at \(workspaceRoot.path): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Main execution loop

    func run() async {
        guard !Task.isCancelled else { return }
        state = .active

        // One-line startup diagnostic so each new run shows: agent id
        // (short), task type, task description preview, and the
        // resolved provider ID. Crucial when "agent finished too fast
        // with tools=0" — that line tells us instantly whether the
        // user has the right model wired for this task type.
        let providerId = provider?.providerId ?? "<none>"
        print("[TaskAgent \(id.uuidString.prefix(8))] 🚀 starting type=\(taskType.rawValue) provider=\(providerId) task=\"\(taskDescription.prefix(80))\"")

        let memoryBlock = await fetchMemoryBlock()
        let skillsBlock = await fetchSkillsBlock()
        conversationHistory = [
            LLMMessage(role: .system, content: buildSystemPrompt(memoryBlock: memoryBlock, skillsBlock: skillsBlock)),
            LLMMessage(role: .user, content: taskDescription)
        ]

        var loopCount = 0

        while !Task.isCancelled && loopCount < maximumLoopCount {
            loopCount += 1
            await checkAndApplyInterrupts()
            state = .busy

            guard let activeProvider = provider else {
                await handleNoProvider()
                return
            }

            // Re-check cancellation right before the LLM call — these
            // calls take 1–8s and we don't want to pay for one we're
            // about to throw away. The provider also propagates the
            // surrounding Task's cancellation into its URLSession
            // request so a mid-flight call dies cleanly.
            if Task.isCancelled {
                await handleCancellation()
                return
            }

            do {
                let completionResult = try await callProviderWithTransientRetry(
                    provider: activeProvider,
                    messages: conversationHistory,
                    tools: availableToolDefinitions(),
                    loopIndex: loopCount
                )
                tokensUsed += completionResult.tokenUsage?.totalTokens ?? 0

                // Log every response shape so we can diagnose when the
                // agent isn't using tools. The prior version silently
                // accepted text-only responses on tool-mandatory task
                // types when the redirect logic didn't fire for reasons
                // that weren't observable from outside.
                logResponseShape(completionResult.response, loopIndex: loopCount)

                switch completionResult.response {
                case .text(let text):
                    if shouldRedirect(toToolUse: text, toolCallsSoFar: toolCallCount) {
                        await redirectAgentToToolUse(assistantText: text)
                        continue
                    }
                    // The redirect budget is exhausted (or we never
                    // needed one). If we're STILL accepting an empty
                    // response with zero tool calls on a tool-mandatory
                    // task, treat it as a genuine failure — not a
                    // success. The previous behaviour would notify
                    // .taskComplete with an empty summary; voice
                    // Gemini saw "task finished" and chained follow-up
                    // tasks that tried to summarise nothing.
                    let isEmptyTextWithNoTools = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && toolCallCount == 0
                    if isEmptyTextWithNoTools {
                        let reason = "Agent (\(provider?.providerId ?? "unknown")) produced no output and called no tools after \(textOnlyRedirectCount) redirect(s). The model is likely too small for this task type — switch the \(taskType.rawValue) provider to a larger model (e.g. gemini-2.5-pro, gemini-3-pro, claude-sonnet-4-6) in Settings → Agents."
                        await recordStep("✗ empty text-only response after redirect budget — failing", succeeded: false)
                        state = .error(message: reason)
                        await writeTaskResultToMemory(summary: "Failed: \(reason)")
                        let failureExecution = buildTaskExecution(outcome: .failure(reason: reason))
                        await scheduleEfficiencyEvaluation(failureExecution)
                        await swarmManager.send(AgentMessage(
                            from: .task(id),
                            to: .main,
                            type: .taskFailed(reason: reason)
                        ))
                        return
                    }
                    await recordStep(text, succeeded: true)
                    state = .completed
                    await writeTaskResultToMemory(summary: text)
                    await autoSaveSkill(taskResult: text)
                    let successExecution = buildTaskExecution(outcome: .success(summary: text))
                    await scheduleEfficiencyEvaluation(successExecution)
                    await notifyMainAgentOfCompletion(summary: text)
                    return

                case .toolCalls(let calls):
                    // Carry the tool calls on the assistant turn so
                    // the provider can re-emit proper `tool_use`
                    // content blocks (Anthropic rejects the next
                    // request if the assistant turn doesn't have
                    // matching tool_use ids for the tool_result blocks
                    // we're about to send).
                    conversationHistory.append(LLMMessage(
                        role: .assistant,
                        content: "",
                        toolCalls: calls
                    ))
                    if await runToolCallBatch(calls) == .cancelled {
                        await handleCancellation()
                        return
                    }

                case .textAndToolCalls(let text, let calls):
                    // Empty calls means "the model wrote text but called
                    // no tool" — same failure shape as `.text` for
                    // tool-mandatory task types. Redirect.
                    if calls.isEmpty,
                       shouldRedirect(toToolUse: text, toolCallsSoFar: toolCallCount) {
                        await redirectAgentToToolUse(assistantText: text)
                        continue
                    }
                    // Single assistant turn that carries BOTH the
                    // natural-language preamble and the tool calls.
                    // Providers serialise this as a content array
                    // with `[{type:text, ...}, {type:tool_use, ...}]`.
                    conversationHistory.append(LLMMessage(
                        role: .assistant,
                        content: text,
                        toolCalls: calls.isEmpty ? nil : calls
                    ))
                    if !text.isEmpty {
                        await recordStep(text, succeeded: true)
                    }
                    if await runToolCallBatch(calls) == .cancelled {
                        await handleCancellation()
                        return
                    }
                }

            } catch is CancellationError {
                // Mid-retry cancellation (user dismissed the agent
                // while we were backing off between LLM retries).
                // Route through handleCancellation so the overlay
                // shows "Cancelled by user" instead of a cryptic
                // CancellationError reason.
                await handleCancellation()
                return
            } catch {
                await handleError(error)
                return
            }
        }

        if loopCount >= maximumLoopCount {
            await handleError(AgentError.maximumLoopCountExceeded)
        }
    }

    // MARK: - Receiving messages from SwarmManager

    func receive(_ message: AgentMessage) {
        switch message.type {
        case .interrupt(let instruction):
            interruptQueue.append(instruction)
        case .blockerResolved(let response):
            interruptQueue.append("[Blocker resolved]: \(response)")
            if case .blocked = state { state = .active }
        case .chatMessage(let text):
            chatHistory.append(AgentChatMessage(sender: .user, text: text, timestamp: Date()))
            interruptQueue.append("[User message]: \(text)")
        default:
            break
        }
    }

    func markTerminated() {
        state = .terminated
        // Tear down the interactive shell so we don't leak a /bin/zsh
        // subprocess per dismissed agent. Workspace files stay on disk
        // so the user can inspect what the agent did after the fact —
        // they're under ~/Library/Application Support/TipTour/agent-workspaces/.
        Task { await interactiveShellSession.shutdown() }
    }

    // MARK: - Private helpers

    private func checkAndApplyInterrupts() async {
        guard !interruptQueue.isEmpty else { return }
        backtrackCount += 1
        let pendingInstructions = interruptQueue
        interruptQueue.removeAll()
        for instruction in pendingInstructions {
            conversationHistory.append(LLMMessage(role: .user, content: instruction))
        }
        await notifyProgressUpdate("Updating plan based on new instructions...")
    }

    private func recordStep(_ description: String, succeeded: Bool) async {
        currentStep = description
        stepHistory.append(AgentStep(description: description, completedAt: Date(), succeeded: succeeded))
        await notifyProgressUpdate(description)
    }

    private func notifyProgressUpdate(_ stepDescription: String) async {
        await swarmManager.send(AgentMessage(
            from: .task(id),
            to: .main,
            type: .progressUpdate(stepDescription: stepDescription, progressFraction: nil)
        ))
    }

    private func notifyMainAgentOfCompletion(summary: String) async {
        await swarmManager.send(AgentMessage(
            from: .task(id),
            to: .main,
            type: .taskComplete(result: .success(summary: summary, detailJSON: nil))
        ))
    }

    private func handleNoProvider() async {
        let reason = "No LLM provider configured for task type '\(taskType.displayName)'. Add an API key in Settings → Agents."
        await writeTaskResultToMemory(summary: "Failed: \(reason)")
        state = .error(message: reason)
        await swarmManager.send(AgentMessage(from: .task(id), to: .main, type: .taskFailed(reason: reason)))
    }

    private func handleError(_ error: Error) async {
        let reason = error.localizedDescription
        await recordStep("Error: \(reason)", succeeded: false)
        await writeTaskResultToMemory(summary: "Failed: \(reason)")
        let failureExecution = buildTaskExecution(outcome: .failure(reason: reason))
        await scheduleEfficiencyEvaluation(failureExecution)
        state = .error(message: reason)
        await swarmManager.send(AgentMessage(from: .task(id), to: .main, type: .taskFailed(reason: reason)))
    }

    /// Decide whether a text-only response should be rejected ("you
    /// forgot to use tools") or accepted ("legitimate final summary").
    /// Each gate is logged so we can diagnose silent acceptance.
    private func shouldRedirect(toToolUse text: String, toolCallsSoFar: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard toolCallsSoFar == 0 else {
            print("[TaskAgent \(id.uuidString.prefix(8))] not redirecting — agent already used \(toolCallsSoFar) tool(s) this run")
            return false
        }
        guard textOnlyRedirectCount < maximumTextOnlyRedirects else {
            print("[TaskAgent \(id.uuidString.prefix(8))] not redirecting — exceeded \(maximumTextOnlyRedirects) redirect budget, accepting text")
            return false
        }
        switch taskType {
        case .browserResearch, .generalMac, .fileManagement, .coding, .imageGeneration, .videoGeneration:
            // For tool-mandatory task types, ANY text-only response
            // (including the empty/whitespace-only ones gemini-flash
            // produces when it's overwhelmed by the system prompt)
            // counts as a failure to act. Length floor removed —
            // previously a 0-char response was treated as a legitimate
            // tiny completion ("Done.") and accepted, which made the
            // agent finish with no work and let downstream voice
            // logic chain follow-up tasks that summarised non-existent
            // results.
            print("[TaskAgent \(id.uuidString.prefix(8))] 🚧 redirecting text-only response — task type \(taskType.rawValue) requires tool use (redirect #\(textOnlyRedirectCount + 1), text length=\(trimmed.count))")
            return true
        case .analysis, .writing:
            // Text-only is legitimate for analysis / writing — those
            // tasks often have no tool to call. But empty replies are
            // still a failure; reject those.
            if trimmed.isEmpty {
                print("[TaskAgent \(id.uuidString.prefix(8))] 🚧 redirecting empty response on \(taskType.rawValue) — model returned no usable output")
                return true
            }
            return false
        }
    }

    /// Append the LLM's text + a corrective user nudge, increment the
    /// redirect counter, and record a visible step so the user sees
    /// the redirect in the agent's detail card.
    private func redirectAgentToToolUse(assistantText: String) async {
        textOnlyRedirectCount += 1
        await recordStep("⚠️ refused text-only response — re-prompting for tool use (\(textOnlyRedirectCount)/\(maximumTextOnlyRedirects))", succeeded: false)
        conversationHistory.append(LLMMessage(role: .assistant, content: assistantText))

        // The corrective nudge names the specific tools available so
        // a small model can copy/paste rather than guess. For
        // browserResearch we lead with chrome_control + open_url
        // since those produce immediate visible action.
        let toolHint: String
        switch taskType {
        case .browserResearch:
            toolHint = "Call open_url(url:…) or chrome_control(operation:\"open_url\", url:…) right now. Then call read_ax_tree or chrome_control(operation:\"execute_javascript\", javascript:…) to OBSERVE the page. Do not narrate — call the tool."
        case .generalMac:
            toolHint = "Call smart_click(label:…), read_ax_tree, type_text(text:…), or open_url(url:…) right now. Do not describe — DO."
        case .fileManagement:
            toolHint = "Call write_file(path:…,contents:…), read_file(path:…), or list_directory(path:…) right now."
        case .coding:
            toolHint = "Call read_file, run_shell_command, or interactive_shell right now."
        case .imageGeneration:
            toolHint = "Call generate_image(prompt:…) right now."
        case .videoGeneration:
            toolHint = "Call generate_video(prompt:…) right now."
        case .analysis, .writing:
            toolHint = "Call any available tool."
        }

        conversationHistory.append(LLMMessage(
            role: .user,
            content: """
            ❌ Your last response had no tool calls. Text-only answers are a FAILURE for task type \(taskType.displayName).
            The user can't see anything happen if you don't call a tool. \(toolHint)
            Your NEXT response MUST be a tool call. Do not apologise, do not explain — just call the tool.
            """
        ))
    }

    /// Call the provider with manual exponential-backoff retry for
    /// transient errors. The most common transient is Anthropic's
    /// HTTP 529 `overloaded_error` — Claude's load shedding under
    /// peak demand. Without retry, a single 529 used to kill the
    /// agent's whole run. Now we retry up to 4 times with 1s → 2s →
    /// 4s → 8s backoff, which usually rides out the overload window
    /// without the user noticing.
    ///
    /// We deliberately do NOT retry permanent errors (400/401/403/404):
    /// those mean the request is malformed or unauthorised and no
    /// number of retries will help. Fail loud so the user sees the
    /// real cause.
    private func callProviderWithTransientRetry(
        provider: any LLMProvider,
        messages: [LLMMessage],
        tools: [LLMTool],
        loopIndex: Int
    ) async throws -> LLMCompletionResult {
        let agentTag = id.uuidString.prefix(8)
        let maxAttempts = 4
        var attemptNumber = 0
        var nextDelay: TimeInterval = 1.0
        let maxDelay: TimeInterval = 8.0
        var lastError: Error?

        while attemptNumber < maxAttempts {
            attemptNumber += 1
            // Honor cancellation between retries — no point sleeping
            // and retrying if the user already dismissed the agent.
            if Task.isCancelled {
                throw CancellationError()
            }
            do {
                return try await provider.complete(messages: messages, tools: tools)
            } catch let error as LLMProviderError {
                lastError = error
                // Permanent error → bail out immediately; no retry.
                if !Self.isTransient(providerError: error) {
                    print("[TaskAgent \(agentTag) loop=\(loopIndex)] non-retryable \(provider.providerId) error: \(error.localizedDescription)")
                    throw error
                }
                // Exhausted budget → surface the last error.
                if attemptNumber >= maxAttempts {
                    print("[TaskAgent \(agentTag) loop=\(loopIndex)] ⏳ all \(maxAttempts) attempts failed for \(provider.providerId)")
                    throw error
                }
                // Transient → record + sleep + retry. Visible in the
                // agent's detail card as a "⏳ retrying" step.
                await recordTransientError(error, attempt: attemptNumber, of: maxAttempts, nextDelay: nextDelay)
                try? await Task.sleep(nanoseconds: UInt64(nextDelay * 1_000_000_000))
                nextDelay = min(nextDelay * 2, maxDelay)
            } catch {
                // Non-LLMProviderError (URLError, CancellationError,
                // generic network failure). Retry once with the same
                // backoff curve — network blips are common.
                lastError = error
                if attemptNumber >= maxAttempts {
                    print("[TaskAgent \(agentTag) loop=\(loopIndex)] ⏳ all \(maxAttempts) attempts failed with non-provider error: \(error.localizedDescription)")
                    throw error
                }
                print("[TaskAgent \(agentTag) loop=\(loopIndex)] ⏳ attempt \(attemptNumber) failed (\(error.localizedDescription)) — retrying in \(String(format: "%.1f", nextDelay))s")
                try? await Task.sleep(nanoseconds: UInt64(nextDelay * 1_000_000_000))
                nextDelay = min(nextDelay * 2, maxDelay)
            }
        }
        // Loop exit without return — only reachable if every attempt
        // both failed AND we somehow skipped the explicit `throw`s
        // above. Defensive fallthrough.
        throw lastError ?? LLMProviderError.decodingError("Retry budget exhausted with no recorded error")
    }

    /// Classify whether a `LLMProviderError` is worth retrying.
    /// Transient: server load (529, 503), gateway issues (502, 504),
    /// rate limits (429), and request timeouts (408). Everything else
    /// is treated as permanent.
    private static func isTransient(providerError: LLMProviderError) -> Bool {
        switch providerError {
        case .httpError(let statusCode, _):
            return [408, 429, 500, 502, 503, 504, 520, 522, 524, 529].contains(statusCode)
        case .missingAPIKey, .decodingError, .unsupportedOperation:
            return false
        }
    }

    /// Append a non-throwing step to the agent's history so the user
    /// can see "the LLM got 529 and we're retrying in 2s" in the
    /// detail card without having to dig into the Xcode console.
    private func recordTransientError(
        _ error: LLMProviderError,
        attempt: Int,
        of maxAttempts: Int,
        nextDelay: TimeInterval
    ) async {
        let header: String
        if case .httpError(let statusCode, _) = error {
            header = "⏳ Provider returned \(statusCode)"
        } else {
            header = "⏳ Provider error"
        }
        let summary = "\(header) — attempt \(attempt)/\(maxAttempts), retrying in \(String(format: "%.1f", nextDelay))s"
        await recordStep(summary, succeeded: false)
        print("[TaskAgent \(id.uuidString.prefix(8))] \(summary): \(error.localizedDescription)")
    }

    /// Print a one-line summary of what the LLM just produced so we
    /// can tell at a glance whether tools were called, just text, or
    /// both. Crucial for debugging "agent finished too fast with
    /// tools=0" cases.
    private func logResponseShape(_ response: LLMResponse, loopIndex: Int) {
        let prefix = "[TaskAgent \(id.uuidString.prefix(8)) loop=\(loopIndex)]"
        switch response {
        case .text(let text):
            print("\(prefix) response=.text length=\(text.count) preview=\"\(text.prefix(80))…\"")
        case .toolCalls(let calls):
            let names = calls.map(\.name).joined(separator: ", ")
            print("\(prefix) response=.toolCalls count=\(calls.count) names=[\(names)]")
        case .textAndToolCalls(let text, let calls):
            let names = calls.map(\.name).joined(separator: ", ")
            print("\(prefix) response=.textAndToolCalls textLen=\(text.count) toolCount=\(calls.count) names=[\(names)]")
        }
    }

    /// Spawn the efficiency-monitor evaluation as a side task registered
    /// with the swarm so `terminate` can cancel its in-flight LLM call.
    /// Without this registration the evaluation Task would survive the
    /// agent and keep charging the user for inference they won't see.
    private func scheduleEfficiencyEvaluation(_ execution: TaskExecution) async {
        let evaluationTask = Task { [agentId = self.id] in
            // Bail immediately if the agent was already terminated
            // between the Task creation and its first scheduling slot.
            if Task.isCancelled { return }
            let report = await EfficiencyMonitor.shared.evaluate(execution)
            // Surface the score even when no self-critique fires —
            // fixes finding #14 (reports were thrown away).
            print("[EfficiencyMonitor] agent=\(agentId) score=\(String(format: "%.2f", report.inefficiencyScore)) tools=\(execution.toolCallCount) tokens=\(execution.tokensUsed) selfCritique=\(report.didSelfCritique)")
        }
        await swarmManager.registerSideTask(evaluationTask, forAgent: id)
    }

    private func availableToolDefinitions() -> [LLMTool] {
        toolBox.definitions
    }

    private func dispatchToolCall(_ toolCall: LLMToolCall) async -> String {
        toolCallCount += 1
        let result = await toolBox.execute(toolCall: toolCall)
        skillHistoryBuffer.append(RecordedToolCall(
            toolName: toolCall.name,
            argumentsJSON: toolCall.argumentsJSON,
            result: result
        ))
        return result
    }

    /// Outcome of running a batch of tool calls in sequence.
    private enum ToolBatchOutcome {
        case completed
        case cancelled
    }

    /// Dispatch tool calls one at a time, checking for cancellation
    /// between calls so an in-flight `terminate` doesn't have to wait
    /// out a full batch. Each tool result is appended to the
    /// conversation history before the next tool runs.
    private func runToolCallBatch(_ calls: [LLMToolCall]) async -> ToolBatchOutcome {
        for toolCall in calls {
            if Task.isCancelled {
                return .cancelled
            }
            // Record the invocation as one step with a compact argument
            // preview, then run the tool, then record a second step
            // with a preview of the result. This gives the user a
            // readable timeline of "what the agent tried" and "what
            // it got back" — much more informative than the previous
            // single "Calling tool: X" step.
            let argumentsPreview = compactJSONPreview(toolCall.argumentsJSON, maxLength: 120)
            await recordStep("→ \(toolCall.name)(\(argumentsPreview))", succeeded: true)

            let toolResult = await dispatchToolCall(toolCall)
            conversationHistory.append(LLMMessage(
                role: .tool,
                content: toolResult,
                toolCallId: toolCall.id,
                toolName: toolCall.name
            ))

            let toolSucceeded = !toolResult.lowercased().hasPrefix("error")
            let resultPreview = String(toolResult.prefix(220))
                .replacingOccurrences(of: "\n", with: " ")
            await recordStep("   \(resultPreview)", succeeded: toolSucceeded)
        }
        return .completed
    }

    /// Compact a tool-call arguments JSON string for display in the
    /// agent overlay. Strips leading `{` / trailing `}` and any
    /// whitespace so a 4-argument JSON renders as "label: Save, app: ..."
    /// rather than wrapping awkwardly in the step list.
    private func compactJSONPreview(_ json: String, maxLength: Int) -> String {
        let trimmed = json
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }

    /// Surface a clean cancellation summary to the user instead of a
    /// silent void. The swarm has already marked the agent `.terminated`
    /// at this point via `markTerminated()`, so we just record a final
    /// step + memory entry so the audit trail is complete.
    private func handleCancellation() async {
        let summary = "Cancelled by user before completion. Completed \(stepHistory.count) step(s)."
        await recordStep(summary, succeeded: false)
        await writeTaskResultToMemory(summary: summary)
        // Tear down the interactive shell on the self-detected
        // cancellation path too. `markTerminated` does the same when
        // SwarmManager initiates termination, but self-detection runs
        // before that callback in some race orderings.
        await interactiveShellSession.shutdown()
        // Do NOT overwrite the state if SwarmManager already set
        // .terminated — that's the canonical "user dismissed me" state.
        // If we got here from a self-detected cancellation (e.g. parent
        // task cancelled but markTerminated hasn't run yet), default
        // to .terminated so the overlay shows the right thing.
        if state != .terminated {
            state = .terminated
        }
        await swarmManager.send(AgentMessage(
            from: .task(id),
            to: .main,
            type: .taskFailed(reason: "Cancelled by user")
        ))
    }

    /// Queries the shared memory store for entries relevant to this task,
    /// returning a formatted block to prepend to the system prompt.
    /// Returns an empty string when no relevant memories exist.
    private func fetchMemoryBlock() async -> String {
        let memories = await AgentMemoryStore.shared.query(
            taskDescription: taskDescription,
            taskTypes: [taskType]
        )
        guard !memories.isEmpty else { return "" }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let lines = memories.enumerated().map { index, entry in
            let typeLabel = entry.entryType == .fact ? "fact" : "task result"
            let expiryLabel: String
            if let expiresAt = entry.expiresAt {
                expiryLabel = "expires \(dateFormatter.string(from: expiresAt))"
            } else {
                expiryLabel = "permanent"
            }
            return "\(index + 1). \(entry.content) (\(typeLabel), \(expiryLabel))"
        }.joined(separator: "\n")
        return "--- Relevant memory ---\n\(lines)\n---"
    }

    /// Queries the shared skill library for skills relevant to this task,
    /// returning a formatted block to prepend to the system prompt.
    /// Returns an empty string when no relevant skills exist.
    ///
    /// The library is seeded at app launch with ~150 prompts from RuFlo
    /// (SPARC, DDD, GitHub workflows, security audit, etc.) and OpenWork
    /// (OpenCode primitives, browser-setup, release flow, etc.). The
    /// query scores entries by taskType match + keyword overlap, so the
    /// agent receives only the slugs most relevant to its current task —
    /// not the whole 150-skill catalog. The agent can then call
    /// `recall_skill` to fetch the full body of any listed slug before
    /// acting.
    private func fetchSkillsBlock() async -> String {
        let skills = await SkillLibraryStore.shared.query(
            taskDescription: taskDescription,
            taskTypes: [taskType]
        )
        guard !skills.isEmpty else { return "" }
        let lines = skills.enumerated().map { index, entry in
            "\(index + 1). \(entry.slug): \(entry.description)"
        }.joined(separator: "\n")
        return """
        --- Relevant skills (call `recall_skill(slug)` to read the full body) ---
        \(lines)
        ---
        Each entry above is a battle-tested prompt pattern from RuFlo or \
        OpenWork. When a listed skill matches your subtask, fetch its body \
        and follow its method before improvising — these embody methodologies \
        like SPARC, TDD, security audit, that produce better outcomes than \
        free-form work.
        """
    }

    /// Writes a task-result entry to the shared memory store summarising what this agent did.
    /// Called on completion (success or error). Skipped only for terminated agents.
    private func writeTaskResultToMemory(summary: String) async {
        let content = "\(taskType.displayName): \(taskDescription). \(String(summary.prefix(300)))"
        await AgentMemoryStore.shared.write(
            content: content,
            entryType: .taskResult,
            taskTypes: [taskType],
            permanent: false
        )
    }

    private func buildTaskExecution(outcome: TaskOutcome) -> TaskExecution {
        TaskExecution(
            taskId: id,
            taskType: taskType,
            taskDescription: taskDescription,
            tokensUsed: tokensUsed,
            toolCallCount: toolCallCount,
            backtrackCount: backtrackCount,
            stepsExecuted: stepHistory.count,
            duration: Date().timeIntervalSince(startedAt),
            outcome: outcome,
            conversationHistory: conversationHistory,
            // Use the post-dedup slug from autoSaveSkill so the
            // efficiency monitor's rewrite lands on the file we
            // actually wrote, not a sibling.
            autoSavedSkillSlug: autoSavedSkillSlugForThisRun
        )
    }

    /// Auto-saves a skill to the shared skill library after a successful task completion.
    /// Only saves when the agent meaningfully used tools — pure text
    /// responses, or runs where the only tool calls were `recall_*` /
    /// `remember_*` (shared memory plumbing), don't produce reusable
    /// skills worth storing.
    private func autoSaveSkill(taskResult: String) async {
        let toolCalls = skillHistoryBuffer.calls
        guard !toolCalls.isEmpty else { return }
        // Don't pollute the skill library with runs whose only tool
        // calls were memory/skill metadata reads. Those aren't
        // reusable "how-to" sequences — they're just bookkeeping.
        let memoryOnlyToolNames: Set<String> = [
            "remember_fact", "recall_facts", "save_skill", "recall_skill"
        ]
        let hasDomainToolCall = toolCalls.contains { !memoryOnlyToolNames.contains($0.toolName) }
        guard hasDomainToolCall else { return }

        let baseSlug = SkillLibraryStore.generateSlug(from: taskDescription)
        let body = SkillBodyBuilder.build(
            name: taskDescription,
            toolCalls: toolCalls,
            resultSummary: taskResult
        )
        // Capture the post-dedup slug so EfficiencyMonitor can find
        // this exact file when it wants to rewrite it.
        autoSavedSkillSlugForThisRun = await SkillLibraryStore.shared.write(
            slug: baseSlug,
            name: taskDescription,
            description: String(taskResult.prefix(120)),
            taskTypes: [taskType],
            body: body
        )
    }

    private func buildSystemPrompt(memoryBlock: String, skillsBlock: String) -> String {
        var extras = ""
        if !memoryBlock.isEmpty { extras += "\n\(memoryBlock)" }
        if !skillsBlock.isEmpty { extras += "\n\(skillsBlock)" }
        return """
        You are a background task agent running inside TipTour, a macOS AI assistant.
        Your task type: \(taskType.displayName)

        \(toolUsageDoctrine(for: taskType))

        Be concise and direct. Do not ask clarifying questions — make reasonable assumptions and proceed.

        OUTPUT FORMAT: When you have completed the task, respond with a clear text summary describing (a) what tools you actually called, (b) what you observed, and (c) the answer to the user's original request. If you cannot complete the task, explain exactly which tool failed and why.

        BUDGET: You have a hard cap of \(maximumLoopCount) reasoning turns total. Each tool call counts as one turn. The system will kill you with no summary if you exceed it, so:
          - If you've used roughly 40 turns and the task isn't done, wrap up with a partial summary instead of continuing.
          - Prefer batching independent tool calls in one turn over chaining them across many.
          - If a tool keeps failing the same way, stop retrying and report the failure rather than burning more turns.\(extras)
        """
    }

    /// Per-task-type rules about WHEN to use tools vs answer from
    /// training data. Without this, the LLM defaults to text-only
    /// responses for tasks like "search Amazon for cameras" because
    /// answering from training data is the easier path — but the
    /// whole point of the swarm is that the user sees the agent
    /// actually do the work on their machine.
    private func toolUsageDoctrine(for taskType: TaskType) -> String {
        switch taskType {
        case .browserResearch:
            return """
            MANDATORY TOOL USE:
            This task REQUIRES driving a real browser. You MUST start by calling open_url or chrome_control(operation: "open_url", url: ...) to navigate to the relevant site. You MUST then call read_ax_tree or chrome_control(operation: "execute_javascript", ...) to actually OBSERVE what's on the page. Only then synthesize an answer.
            Do NOT answer from your training data alone — the user wants to SEE you doing the research on their screen and trust that the information is current. A text-only response with no tool calls is a FAILURE for this task type.
            Example flow for "search Amazon for vlogging cameras":
              1. open_url(url: "https://www.amazon.com/s?k=vlogging+camera", browser_bundle_id: "com.google.Chrome")
              2. wait briefly via a no-op tool call OR ask chrome_control(operation: "current_title") to confirm the page loaded
              3. chrome_control(operation: "execute_javascript", javascript: "Array.from(document.querySelectorAll('[data-component-type=\\"s-search-result\\"] h2 a span')).slice(0,10).map(e=>e.innerText).join('\\\\n')") to extract the top results
              4. Summarise the products you actually observed.
            """
        case .generalMac:
            return """
            TOOL-FIRST POLICY:
            You have full GUI access (smart_click, read_ax_tree, type_text, press_keyboard_shortcut, open_url, run_applescript, run_shell_command). For anything the user could ALSO do by clicking around their Mac, you MUST do it via tools — don't describe it in text and stop. The user wants the work performed, not narrated.
            Prefer smart_click (auto-picks AppleScript/AXPress/cursor click per app) over the lower-level primitives unless you need a specific channel.
            """
        case .coding:
            return """
            TOOL-FIRST POLICY:
            For coding tasks: read the actual files with read_file before proposing changes, write changes with write_file, validate with run_shell_command. Do not describe code from memory — read the real source, modify it, and verify.
            For complex multi-step edits, delegate to spawn_claude_code which has its own full tool surface.
            """
        case .fileManagement:
            return """
            TOOL-FIRST POLICY:
            Use list_directory + read_file + write_file + run_shell_command to actually perform the file operations. Do not just describe what you would do — do it.
            """
        case .analysis, .writing:
            return """
            You can use read_file, list_directory, web_fetch to gather material, then synthesize. Text-only responses are acceptable for pure analysis/writing where no external work is required.
            """
        case .imageGeneration, .videoGeneration:
            return """
            MANDATORY TOOL USE:
            You MUST call the generation tool (generate_image / generate_video) to actually produce the output. A text description of what you would generate is a FAILURE — the user wants the file.
            """
        }
    }

    /// Maximum reasoning turns before the run loop kills the agent.
    /// Exposed as a property so the system prompt and the run loop
    /// reference the same number — drifting them is exactly the bug
    /// finding #10 was about.
    private let maximumLoopCount: Int = 50
}

// MARK: - AgentState helper

extension AgentState {
    var currentBlocker: AgentBlocker? {
        if case .blocked(let blocker) = self { return blocker }
        return nil
    }
}

// MARK: - Internal errors

private enum AgentError: Error, LocalizedError {
    case maximumLoopCountExceeded

    var errorDescription: String? {
        "Agent exceeded the maximum number of reasoning steps (50). This likely indicates a loop or an unsolvable task."
    }
}
