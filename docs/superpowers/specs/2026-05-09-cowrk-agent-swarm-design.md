# TipTour: Cowrk Agent Swarm — Design Spec
**Date:** 2026-05-09
**Branch:** cowrk-agent-swarm
**Status:** Approved — ready for implementation planning

---

## 1. Vision

TipTour evolves from a single voice-driven cursor guide into a **general-purpose Mac AI agent platform**. The main agent stays voice-first and cursor-based. Behind it, a swarm of background task agents can be spawned at any time to do anything on the Mac simultaneously — browse the web, write code, generate images, make videos, manage files, run terminal commands, or operate any macOS application.

Every agent is model-agnostic. The user controls which LLM handles which task type. TipTour learns from every execution and from user demonstrations, getting faster and smarter over time without any manual configuration.

**Reference architecture sources:**
- [OpenWork](https://github.com/different-ai/openwork) — session management, approval flows, skill system patterns
- [Ruflo](https://github.com/ruvnet/ruflo) — `SwarmCoordinator`, agent lifecycle, task routing, memory backends
- Both ported conceptually to native Swift — no sidecars, no external processes (except `claude` CLI for coding tasks)

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        TipTour macOS                         │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                  LLMProviderRegistry                    │ │
│  │   GeminiLive │ GeminiRest │ Claude │ OpenAI │ Custom   │ │
│  └────────────────────────────────────────────────────────┘ │
│           │                          │                       │
│  ┌────────▼──────────┐   ┌──────────▼─────────────────────┐ │
│  │    MainAgent      │   │       AgentSwarmManager         │ │
│  │  (CompanionMgr)   │◄──│       (Swift actor)             │ │
│  │  Voice + cursor   │   │  Spawns, routes, tracks agents  │ │
│  └───────────────────┘   └──────────┬──────────────────────┘ │
│                                     │                        │
│              ┌──────────────────────┤                        │
│              │          │           │                        │
│       ┌──────▼──┐ ┌─────▼───┐ ┌────▼────┐                  │
│       │TaskAgent│ │TaskAgent│ │TaskAgent│   ...             │
│       │ Claude  │ │ GPT-4o  │ │ Gemini  │                   │
│       └──────┬──┘ └─────┬───┘ └────┬────┘                  │
│              └──────────┴──────────┘                        │
│        Shared: ActionExecutor · AXTree · ScreenCapture       │
│                WebSession · TerminalRunner                    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │            AgentOverlayStack (top-right)              │   │
│  │   [● Camera Search]  [⚠ Auth Refactor]  [✅ Banner]  │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │         Self-Improvement Layer                        │   │
│  │   AgentMemory · SkillLibrary · EfficiencyMonitor      │   │
│  │   DemonstrationRecorder · SkillExtractor              │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**Core principle:** Everything is native Swift. No Node.js, no Python sidecars. The only external subprocess is the `claude` CLI, spawned by `SpawnClaudeCodeTool` for coding tasks.

---

## 3. LLMProvider Abstraction + Task Routing

### 3.1 LLMProvider Protocol

```swift
protocol LLMProvider {
    var id: String { get }
    var displayName: String { get }
    var supportsVoice: Bool { get }       // only GeminiLive, OpenAI Realtime
    var supportsStreaming: Bool { get }
    var costTier: CostTier { get }        // .free | .low | .medium | .high

    func complete(
        messages: [LLMMessage],
        tools: [LLMTool]
    ) async throws -> LLMResponse

    func stream(
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> AsyncThrowingStream<LLMChunk, Error>
}
```

**Concrete implementations:**

| Class | Provider | Voice | Best for |
|---|---|---|---|
| `GeminiLiveProvider` | Google Gemini Live | ✅ | Main agent (existing) |
| `GeminiRestProvider` | Gemini Flash / Pro | ❌ | Fast browser/research tasks |
| `AnthropicProvider` | Claude Haiku/Sonnet/Opus | ❌ | Coding, reasoning, analysis |
| `OpenAIProvider` | GPT-4o, GPT-4o-mini, o3 | ❌ | General, browser tasks |
| `OpenAIRealtimeProvider` | OpenAI Realtime API | ✅ | Alternative main agent voice |

### 3.2 Task Profiles

```swift
enum TaskType: String, CaseIterable {
    case coding, browserResearch, imageGeneration, videoGeneration,
         fileManagement, generalMac, analysis, writing
}

struct TaskProfile {
    var taskType: TaskType
    var preferredProvider: String          // LLMProvider.id
    var fallbackProvider: String?
    var allowedTools: Set<ToolCategory>
    var tokenBudget: Int                   // soft limit; triggers self-critique if exceeded
    var preferredModel: String             // e.g. "claude-sonnet-4-6"
}
```

**Default task → model mappings (all user-overridable in Settings):**

| Task | Default Model | Reason |
|---|---|---|
| `.coding` | Claude Sonnet 4.6 | Best code understanding; uses `claude` CLI |
| `.browserResearch` | GPT-4o or Gemini Flash | Fast, cheap, good at web navigation |
| `.imageGeneration` | DALL-E 3 / Stability | Configured image API |
| `.videoGeneration` | Gemini / Runway | Configured video API |
| `.fileManagement` | Claude Haiku | Simple, cheap, fast |
| `.generalMac` | Claude Sonnet | Broad capability |
| `.analysis` | Claude Opus | Deep reasoning |

### 3.3 LLMProviderRegistry

```swift
actor LLMProviderRegistry {
    func provider(for taskType: TaskType) -> LLMProvider
    func voiceProviders() -> [LLMProvider]           // supportsVoice == true only
    func setProfile(_ profile: TaskProfile, for taskType: TaskType)
    func register(_ provider: LLMProvider)
    func setMainAgentProvider(_ providerId: String)
}
```

Changes to the registry take effect on next agent spawn — no restart required.

---

## 4. AgentSwarmManager

Ported from Ruflo's `SwarmCoordinator`. Owns the lifecycle of all task agents.

```swift
actor AgentSwarmManager {
    private var agents: [UUID: TaskAgent] = [:]
    private var metrics: [UUID: AgentMetrics] = [:]

    let messageBus = PassthroughSubject<AgentMessage, Never>()
    let overlayState = CurrentValueSubject<[AgentStatus], Never>([])

    // Lifecycle
    func spawn(task: String, type: TaskType, profile: TaskProfile? = nil) async -> TaskAgent
    func terminate(_ agentId: UUID, reason: TerminationReason) async
    func terminateAll() async

    // Communication
    func send(_ message: AgentMessage) async
    func status(of agentId: UUID) -> AgentStatus?
    func allStatuses() -> [AgentStatus]

    // Queries
    func activeAgents() -> [TaskAgent]
    func agent(id: UUID) -> TaskAgent?
}
```

### 4.1 Agent Lifecycle States

```
spawning → active → busy → idle → terminated
                      │
                      ├──► blocked → resolved → busy
                      │         └──► dismissed → terminated
                      │
                      └──► error → retry → busy
                                └──► terminated
```

### 4.2 AgentMessage Bus

All inter-agent communication flows through `AgentSwarmManager.messageBus`. Agents never reference each other directly.

```swift
struct AgentMessage {
    let id: UUID
    let from: AgentID              // .main | .task(UUID) | .swarm
    let to: AgentID
    let type: MessageType
    let payload: AgentPayload
    let timestamp: Date
}

enum MessageType {
    case taskComplete(result: TaskResult)
    case blockerRaised(blocker: AgentBlocker)
    case blockerResolved(response: String)
    case progressUpdate(step: String, progress: Double?)
    case spawnRequest(task: String, type: TaskType, profile: TaskProfile?)
    case interrupt(instruction: String)
    case statusQuery
    case statusResponse(status: AgentStatus)
    case chatMessage(text: String)         // mid-task direct chat
}
```

### 4.3 AgentMetrics

```swift
struct AgentMetrics {
    let agentId: UUID
    var tasksCompleted: Int
    var tasksFailed: Int
    var totalTokensUsed: Int
    var averageDurationSeconds: Double
    var successRate: Double
    var lastActive: Date
}
```

---

## 5. TaskAgent

Each task agent owns its own LLM session, tool execution loop, and interrupt queue.

```swift
actor TaskAgent: Identifiable {
    let id: UUID
    let taskDescription: String
    let taskType: TaskType
    let provider: LLMProvider
    let toolBox: ToolBox
    let swarmManager: AgentSwarmManager
    let memory: AgentMemory
    let skillLibrary: SkillLibrary

    private var conversationHistory: [LLMMessage] = []
    private var interruptQueue: [InterruptMessage] = []
    private(set) var state: AgentState = .spawning
    private(set) var currentStep: String = ""
    private(set) var stepHistory: [AgentStep] = []

    func run() async
    func interrupt(with message: InterruptMessage) async
    func pause() async
    func resume() async
}
```

### 5.1 Agent Execution Loop

```
1. Search SkillLibrary for matching skills
2. Build system prompt: task + relevant skills + available tools
3. Loop:
   a. Call LLM with conversation history + tools
   b. Parse response — text or tool call
   c. If text → progress update to overlay
   d. If tool call → execute tool, append result to history
   e. Check interrupt queue between every tool call
   f. If blocked → raise blocker to main agent, pause
   g. If task complete → run reflection, notify main agent
4. Post-completion: EfficiencyMonitor evaluates, SkillExtractor runs
```

### 5.2 Interrupt Handling

Interrupts are checked between tool calls — never mid-action — so no atomic operation is broken.

```swift
private func checkInterrupts() async {
    guard !interruptQueue.isEmpty else { return }
    let pending = interruptQueue.removeAll()
    for interrupt in pending {
        conversationHistory.append(LLMMessage(
            role: .user,
            content: "[Instruction update]: \(interrupt.instruction)"
        ))
    }
    // LLM re-reasons with updated instructions on next loop iteration
}
```

---

## 6. Tool System

Every `TaskAgent` receives a `ToolBox` at spawn time containing tools appropriate for its `TaskType`.

```swift
protocol AgentTool {
    var name: String { get }
    var category: ToolCategory { get }
    var description: String { get }       // injected into LLM system prompt
    var parameters: JSONSchema { get }
    func execute(_ input: ToolInput) async throws -> ToolOutput
}

struct ToolBox {
    private var tools: [String: AgentTool] = [:]

    static func build(for profile: TaskProfile) -> ToolBox
    func tool(named name: String) -> AgentTool?
    func allDescriptions() -> [LLMTool]   // formatted for LLM system prompt
}
```

### 6.1 Full Tool Registry

**Browser tools:**

| Tool | What it does |
|---|---|
| `BrowserNavigate` | Open URL in default browser |
| `BrowserClick` | Click element by AX label or coordinates |
| `BrowserType` | Type into focused field |
| `BrowserScrape` | Extract visible text/data from current page |
| `WebSearch` | Search and return top N results with snippets |
| `BrowserScroll` | Scroll page up/down/to element |
| `BrowserScreenshot` | Screenshot current browser state |

**Screen / Mac control tools:**

| Tool | What it does |
|---|---|
| `ScreenCapture` | Full screenshot (existing `CompanionScreenCaptureUtility`) |
| `ReadAXTree` | AX tree of frontmost app (existing `AccessibilityTreeResolver`) |
| `ClickElement` | Click any UI element by label (existing `ActionExecutor`) |
| `TypeText` | Synthetic keyboard input (existing `ActionExecutor`) |
| `PressKeyCombo` | e.g. Cmd+S, Cmd+Tab |
| `OpenApplication` | Launch any app by name |
| `SwitchToApp` | Bring app to foreground |

**Terminal / filesystem tools:**

| Tool | What it does |
|---|---|
| `RunShellCommand` | Execute any shell command, stream output |
| `SpawnClaudeCode` | Run `claude` CLI in a project directory |
| `ReadFile` | Read file contents at path |
| `WriteFile` | Write/create file |
| `ListDirectory` | Directory listing with metadata |
| `MoveFile` | Move or rename file/folder |
| `DeleteFile` | Delete with confirmation |
| `FindFiles` | Search by name/extension/content |

**Generation tools:**

| Tool | What it does |
|---|---|
| `GenerateImage` | Call configured image API (DALL-E, Stability, Flux) |
| `GenerateVideo` | Call configured video API (Runway, Kling, Haiper, Gemini) |
| `GenerateAudio` | Call configured audio/TTS API |

**Coordination tools:**

| Tool | What it does |
|---|---|
| `SpawnSubAgent` | Ask SwarmManager to spawn a child agent |
| `NotifyMainAgent` | Send completion/blocker message to main agent |
| `ReportProgress` | Update overlay panel step + progress bar |
| `RaiseBlocker` | Pause and surface blocker to main agent |

**Memory / learning tools:**

| Tool | What it does |
|---|---|
| `SearchSkillLibrary` | Semantic search for relevant past skills |
| `SaveSkill` | Persist a new skill after reflection |
| `RecallMemory` | Find similar past task executions |
| `WebDiscover` | Search web for new approaches to current task |

### 6.2 SpawnClaudeCode Detail

```swift
struct SpawnClaudeCodeTool: AgentTool {
    // Spawns: claude --project-dir <path> --message <task> --output-format stream-json
    // Streams stdout back to TaskAgent as progress updates
    // TaskAgent surfaces each update to its overlay panel in real time
    // Returns final result when claude CLI exits
    func execute(_ input: ToolInput) async throws -> ToolOutput
}
```

This gives any task agent full Claude Code power on any local project directory — file edits, terminal commands, multi-file reasoning — without any additional setup.

---

## 7. Self-Improvement Layer

### 7.1 Execution Memory

```swift
struct MemoryEntry {
    let id: UUID
    let taskDescription: String
    let taskType: TaskType
    let approach: String              // what the agent did, step by step
    let toolsUsed: [String]
    let servicesUsed: [URL]
    let outcome: TaskOutcome          // .success(result) | .failure(reason) | .partial
    let tokensUsed: Int
    let durationSeconds: Double
    let embedding: [Float]            // Apple NaturalLanguage framework — on-device, private
    let timestamp: Date
}

actor AgentMemory {
    func store(_ entry: MemoryEntry) async throws
    func recall(similarTo query: String, limit: Int) async -> [MemoryEntry]
    func topApproaches(for taskType: TaskType) async -> [MemoryEntry]
    func updateOutcome(_ id: UUID, success: Bool) async
}
```

Embedding uses Apple's `NaturalLanguage` framework for on-device sentence vectors — no API cost, fully private. Backed by SQLite for persistence across app restarts.

### 7.2 Skill Library

```swift
struct Skill: Identifiable, Codable {
    let id: UUID
    let name: String
    let description: String
    let taskTypes: [TaskType]
    let instructions: String           // step-by-step natural language
    let requiredTools: [ToolCategory]
    let preferredProvider: String?     // nil = use task default
    var successRate: Double
    var useCount: Int
    let source: SkillSource
    let createdAt: Date
    var lastUsed: Date?
}

enum SkillSource: Codable {
    case discovered(url: URL)          // found via web search
    case learned                       // extracted from successful execution
    case userDemonstrated              // Watch Me mode — highest trust
    case userDefined                   // manually written by user
}

actor SkillLibrary {
    func add(_ skill: Skill) async
    func match(task: String) async -> [Skill]     // semantic search, ranked by successRate
    func update(_ id: UUID, success: Bool) async
    func allSkills() async -> [Skill]
    func delete(_ id: UUID) async
    func export() async throws -> Data             // JSON export
}
```

User-demonstrated skills have highest routing priority for matching task types, overriding web-discovered and self-learned skills.

### 7.3 Reflection + Discovery Loop

After every task completion (success or failure):

```
Task finishes
    │
    ├─ Success
    │    └─ Short reflection call to LLM:
    │         "Summarize the approach that worked as a reusable skill."
    │         → New/updated Skill saved to SkillLibrary
    │
    └─ Failure
         └─ Reflection call:
              "What went wrong? Search the web for a better approach."
              → Agent uses WebDiscover tool
              → Saves improved approach as new Skill
              → Old skill's successRate decremented
```

Before every task starts:
```
New task arrives
    │
    ▼
SkillLibrary.match(task)
    │
    ├─ High-confidence match → inject skill as system context
    │
    └─ Low confidence / no match → agent discovers on its own,
                                    saves result as new skill after
```

### 7.4 EfficiencyMonitor

```swift
struct TaskExecution {
    let taskId: UUID
    let taskType: TaskType
    var tokensUsed: Int
    var stepsExecuted: Int
    var backtrackCount: Int           // direction reversals
    var toolCallCount: Int
    var duration: TimeInterval
    var outcome: TaskOutcome
}

struct EfficiencyReport {
    let inefficiencyScore: Double     // 0.0 = perfect, 1.0 = very wasteful
    let tokenOverrun: Int             // vs. TaskProfile.tokenBudget
    let wastedSteps: Int
    let diagnosis: String             // LLM-generated explanation
    let shouldSelfCritique: Bool      // true if score > 0.4
}

actor EfficiencyMonitor {
    func evaluate(_ execution: TaskExecution) async -> EfficiencyReport
}
```

When `shouldSelfCritique == true`, a reflection call runs automatically and updates the SkillLibrary. No user involvement needed.

### 7.5 Watch Me — Demonstration Learning

User activates "Watch Me" mode (Ctrl+Option+W) to teach TipTour a task by doing it themselves.

```swift
struct ObservedAction {
    let timestamp: Date
    let type: ActionType              // .click | .type | .keyPress | .appSwitch | .scroll
    let targetLabel: String?          // AX label of element interacted with
    let targetApp: String
    let value: String?                // typed text or key combo
    let screenshot: Data?             // compressed JPEG at each step
}

struct ActionTrajectory {
    let actions: [ObservedAction]
    let duration: TimeInterval
    let appsInvolved: [String]
    let startScreenshot: Data
    let endScreenshot: Data
}

class DemonstrationRecorder {
    func startRecording()             // amber badge appears top-right
    func stopRecording() -> ActionTrajectory
    // Hooks into existing ClickDetector + CGEventTap + NSWorkspace
}

actor SkillExtractor {
    // Sends trajectory to LLM with prompt:
    // "Here are the steps the user took, with screenshots.
    //  Summarize this as a reusable skill with clear numbered instructions."
    func extract(
        from trajectory: ActionTrajectory,
        taskDescription: String
    ) async throws -> Skill
}
```

**Flow:**
1. Ctrl+Option+W → recording starts, amber badge visible
2. User performs the task manually
3. Ctrl+Option+W again → recording stops
4. TipTour asks (voice or overlay): "What should I call this skill?"
5. User names it
6. `SkillExtractor` synthesizes the skill
7. Saved to SkillLibrary with source `.userDemonstrated`
8. Next matching task uses it immediately

---

## 8. AgentOverlayStack UI

Floating panel stack anchored to top-right of screen. Non-activating NSPanels — never steal focus.

### 8.1 Collapsed State (default)

```
┌───────────────────────────────────┐  ← top-right
│ ●  Camera Research          [−][×]│  ← green pulsing = active
│ ⚠  Auth Refactor            [−][×]│  ← amber = blocked
│ ✅  Banner Image             [−][×]│  ← complete
│ ○   Code Review              [−][×]│  ← idle/queued
│                                   │
│ [+ New Task]                      │
└───────────────────────────────────┘
```

Max 5 panels visible at once. Completed panels auto-dismiss after 30 seconds unless expanded.

### 8.2 Expanded State (click to open)

```
┌─────────────────────────────────────────┐
│ ●  Camera Research               [−][×] │
├─────────────────────────────────────────┤
│ Steps                                   │
│  ✅ Searched "mirrorless camera 2025"  │
│  ✅ Opened rtings.com                  │
│  ✅ Read top 5 picks                   │
│  ⏳ Checking Amazon prices...          │
│  ○  Compare final 3                    │
│  ○  Report to main agent               │
├─────────────────────────────────────────┤
│ Tokens: 3,241  ·  Time: 1m 42s         │
├─────────────────────────────────────────┤
│ Chat with this agent                    │
│ ┌─────────────────────────────────────┐ │
│ │ Budget changed to $500              │ │
│ └──────────────────────[Send ↵]──────┘ │
└─────────────────────────────────────────┘
```

### 8.3 Panel States

| State | Indicator | Behaviour |
|---|---|---|
| `active` | Green pulsing dot | Shows current step + indeterminate progress |
| `busy` | Blue pulsing dot | Tool executing, progress bar shown |
| `blocked` | Amber dot | Shows blocker description + "Tap to resolve" |
| `complete` | ✅ Checkmark | Result summary, fades after 30s |
| `error` | 🔴 Red dot | Error message + Retry button |
| `idle` | Grey dot | Waiting (subtask or queue) |

### 8.4 Data Model

```swift
struct AgentStatus: Identifiable {
    let id: UUID
    let agentName: String
    let taskSummary: String          // short: "Camera Research"
    var state: AgentState
    var currentStep: String
    var stepHistory: [AgentStep]
    var progress: Double?            // nil = indeterminate
    var tokensUsed: Int
    var durationSeconds: Double
    var blocker: AgentBlocker?
    var result: TaskResult?
    var isExpanded: Bool
    var isMinimised: Bool            // collapses to 36×36pt badge
    var chatHistory: [ChatMessage]   // mid-task direct chat
}
```

`AgentSwarmManager.overlayState` (`CurrentValueSubject<[AgentStatus], Never>`) drives the entire stack — SwiftUI observes and re-renders automatically.

### 8.5 Minimised Badge

Each panel can collapse to a 36×36pt badge (icon + state dot). 5 agents minimised take up a single row — no screen clutter.

---

## 9. Message Flow

### 9.1 Happy Path — Task Completes

```
TaskAgent finishes work
    │
    ▼
Runs reflection → saves/updates Skill in SkillLibrary
EfficiencyMonitor evaluates → self-critique if needed
    │
    ▼
Sends AgentMessage(.taskComplete, result, to: .main)
    │
    ▼
AgentSwarmManager routes to MainAgent
    │
    ▼
MainAgent speaks (waits for natural pause in user activity):
  "Your camera search is done —
   I found 3 options under $500. Want to see them?"
    │
    ├─ "Yes" → MainAgent presents results
    │           (opens browser tab, shows overlay card, reads aloud)
    │           TaskAgent panel fades out after 30s
    │
    └─ "Not now" → Result stored in memory, panel stays collapsed
                   User can retrieve later: "show me the camera results"
```

### 9.2 Blocker Path

```
TaskAgent encounters blocker (login, CAPTCHA, ambiguity, confirmation needed)
    │
    ▼
TaskAgent.state → .blocked
Panel turns amber, shows blocker description
Sends AgentMessage(.blockerRaised, blocker, to: .main)
    │
    ▼
MainAgent interrupts user gently (waits for activity pause):
  "Your camera agent hit a snag —
   Amazon wants it to log in. Should I help it?"
    │
    ├─ "Yes" → MainAgent takes over browser via ActionExecutor
    │           Handles login / resolves blocker
    │           Sends AgentMessage(.blockerResolved, to: task)
    │           TaskAgent resumes from checkpoint
    │
    ├─ "Try a different site" → Instruction relayed to TaskAgent
    │                           Agent self-discovers alternative (B&H, etc.)
    │
    └─ "Cancel it" → AgentSwarmManager.terminate(agentId)
```

### 9.3 Auto-Spawn Path

```
User says: "Find me a webcam and also resize these photos in Preview"
    │
    ▼
MainAgent reasons: two independent tasks → spawn two agents
    │
    ▼
Sends AgentMessage(.spawnRequest("find webcam", .browserResearch), to: .swarm)
Sends AgentMessage(.spawnRequest("resize photos in Preview", .generalMac), to: .swarm)
    │
    ▼
Two panels appear top-right
MainAgent stays fully available for voice
```

### 9.4 Mid-Task Interrupt — Direct Chat

```
User clicks expanded panel → types "budget changed to $500, also check B&H"
    │
    ▼
ChatMessage sent directly to TaskAgent.interrupt()
    │
    ▼
InterruptHandler queues message
Checked between next tool calls (never mid-action)
    │
    ├─ Minor change → injected into LLM history as user message
    │                 Agent incorporates and continues
    │
    └─ Major change → agent replans before next step
                      Panel shows: "Updating plan based on your input..."
```

### 9.5 Mid-Task Interrupt — Via Main Agent (Voice)

```
User says: "What's the camera agent doing?"
    │
    ▼
MainAgent calls AgentSwarmManager.status(agentId)
Speaks: "It's on step 4 of 6, checking Amazon prices, been 2 minutes"
    │
User says: "Tell it to also check B&H Photo"
    │
    ▼
MainAgent sends AgentMessage(.interrupt, "also check bhphotovideo.com", to: task)
TaskAgent receives on next tool boundary, incorporates
```

### 9.6 Global Status Sweep

```
User says: "What are all my agents doing?"
    │
    ▼
MainAgent calls AgentSwarmManager.allStatuses()
Speaks: "3 agents running —
  camera search is on step 4,
  auth refactor is blocked waiting for your input,
  banner image finished 2 minutes ago"
```

---

## 10. Spawning — How Agents Are Created

Two paths, both result in the same spawn flow:

**Path A — Main agent auto-spawns** (detects long-running or background-worthy task):
- User speaks a task → MainAgent reasons it's background work → calls `AgentSwarmManager.spawn()`

**Path B — User explicitly spawns** (Ctrl+Option+Shift or "New Task" button):
- Opens a small input panel → user types or speaks task → picks model/type → spawns

Both paths:
```swift
// AgentSwarmManager.spawn()
let profile = registry.profile(for: taskType)  // or user-specified override
let provider = registry.provider(for: taskType)
let toolBox = ToolBox.build(for: profile)
let agent = TaskAgent(task, type, provider, toolBox, memory, skillLibrary)
agents[agent.id] = agent
Task { await agent.run() }                      // structured concurrency
overlayState.send(currentStatuses())            // UI updates immediately
```

---

## 11. Settings UI Additions

New sections in the existing TipTour settings panel:

**Agents tab:**
- Main agent voice provider selector (voice-capable only)
- Task type → model mappings table (editable)
- Token budget per task type
- Max concurrent agents (default: 5)

**Skills tab:**
```
Skills Library                              [+ Add Manual]
─────────────────────────────────────────────────────────
📹 Video via Haiper        ████████░░  94%   [Edit][Del]
🛒 Amazon product search   ██████░░░░  78%   [Edit][Del]
💻 Code via Claude CLI     ██████████ 100%   [Edit][Del]
🖼️ Images via DALL-E       ████████░░  88%   [Edit][Del]

[Export All]  [Import]
```

Source badges: 👤 User demonstrated · 🧠 Self-learned · 🌐 Web discovered · ✏️ Manual

**Learning tab:**
- Watch Me shortcut config (default: Ctrl+Option+W)
- Self-critique threshold (default: 0.4 inefficiency score)
- Memory retention period
- Clear memory / skill library buttons

---

## 12. Key Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| Sidecar vs native | Native Swift only | No process management, single binary, better macOS integration |
| Task agent LLM | REST API (not Live) | Live API is real-time/voice; REST is better for background tasks — cheaper, pauseable, longer context |
| Interrupt timing | Between tool calls | Atomic actions (clicks, types) never interrupted mid-execution |
| Memory embeddings | Apple NaturalLanguage | On-device, private, no API cost |
| Agent communication | Combine PassthroughSubject | Native Swift, no dependencies, already used in TipTour |
| Overlay panels | NSPanel (non-activating) | Never steal focus — same pattern as existing TipTour overlay |
| Claude Code integration | Spawn `claude` CLI subprocess | Gives full Claude Code capability without re-implementing it |
| Skill trust hierarchy | userDemonstrated > learned > discovered | User showing you is ground truth |

---

## 13. Out of Scope (v1)

- Multi-machine agent distribution (Ruflo federation) — add later
- Agent-to-agent direct communication (agents talk only through SwarmManager) — intentional for v1 simplicity
- Sandboxed agent execution (Docker) — no container boundary in v1
- Paid/cloud skill marketplace — local SkillLibrary only
- Mobile companion — macOS only

---

## 14. Implementation Order (for planning)

1. `LLMProvider` protocol + `AnthropicProvider` + `OpenAIProvider` (extend existing `GeminiLiveProvider`)
2. `LLMProviderRegistry` + `TaskProfile` + Settings UI for model routing
3. `AgentSwarmManager` (lifecycle, message bus, overlay state publisher)
4. `TaskAgent` (execution loop, tool dispatch, interrupt handler)
5. Core tool implementations: `RunShellCommand`, `BrowserNavigate`, `ReadAXTree`, `ClickElement`, `WebSearch`
6. `SpawnClaudeCodeTool` (subprocess management, stream output)
7. `AgentOverlayStack` SwiftUI view + expanded panel + direct chat
8. `AgentMemory` (SQLite + Apple NL embeddings)
9. `SkillLibrary` (CRUD + semantic search)
10. `EfficiencyMonitor` + reflection loop
11. `DemonstrationRecorder` + `SkillExtractor` (Watch Me mode)
12. Generation tools: `GenerateImage`, `GenerateVideo`
13. Settings UI additions (Agents tab, Skills tab, Learning tab)
14. End-to-end integration + polish
