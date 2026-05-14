# Plan 5 — Settings Shell + Models, Memory, SOUL Tabs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the user a real Settings surface in the menu bar panel: a tabbed sheet hosting three tabs that round-trip the three Hermes state files the user might want to touch — `config.yaml` (Models tab), `~/.hermes/memories/USER.md` (Memory tab), and `~/.hermes/SOUL.md` (SOUL tab). Plan 4 introduced first-run setup as a one-shot sheet; this plan turns the same primitives into an ongoing-management surface and lets the user verify any provider key against the live provider HTTP endpoint without involving Hermes.

**Architecture:** Adds a new `TipTour/Settings/` directory containing one shell view (`SettingsSheetView`) and three tab views (`ModelsTabView`, `MemoryTabView`, `SoulTabView`). Two thin file-store types (`HermesMemoryStore`, `HermesSoulStore`) own atomic read/write for plain-text user-editable files. A separate `ProviderHealthChecker` protocol + three implementations let the Models tab verify keys against Anthropic / OpenAI / Google's `/v1/models` GET endpoints — independent of Hermes, no LLM cost. The shell uses SwiftUI's `TabView` so adding new tabs (Skills, Guardrails, Gateways, Schedule) in later plans is a one-line addition.

**Tech stack:** SwiftUI `TabView` for the shell, `URLSession` for provider probes (closure-injected for tests), `FileManager` for atomic-rename writes, existing `KeychainStore` for keys, existing `HermesConfigBootstrapper` / `HermesSetupCoordinator` / `HermesRuntimeVersion` from Plan 4. XCTest with `@MainActor async` for all tests; `URLSessionFetchHandler` closure injection avoids the URLProtocol subclass dance.

**Depends on Plan 4** (merged to `main` at commit `de01c1c` 2026-05-14). Plan 5 consumes Plan 4's `HermesConfigBootstrapper`, `HermesSetupCoordinator`, `HermesRuntimeVersion`. Plan 4's post-merge consolidation merged `googleAPIKey` into `geminiAPIKey` — Plan 5 always reads/writes the Google provider's key via `HermesConfigBootstrapper.Provider.google.keychainKey` so it stays robust to future Keychain renames.

---

## File structure

**Create:**
- `TipTour/Settings/SettingsSheetView.swift` — root of the tabbed sheet
- `TipTour/Settings/ModelsTabView.swift` — provider switch + 3 keys + version + test connection
- `TipTour/Settings/MemoryTabView.swift` — USER.md editor
- `TipTour/Settings/SoulTabView.swift` — SOUL.md editor
- `TipTour/Settings/HermesMemoryStore.swift` — atomic read/write for memories/USER.md
- `TipTour/Settings/HermesSoulStore.swift` — atomic read/write for SOUL.md
- `TipTour/Settings/ProviderHealthChecker.swift` — protocol + AnthropicHealthChecker + OpenAIHealthChecker + GoogleHealthChecker + factory
- `TipTourTests/HermesMemoryStoreTests.swift`
- `TipTourTests/HermesSoulStoreTests.swift`
- `TipTourTests/ProviderHealthCheckerTests.swift`
- `TipTourTests/SettingsSheetViewModelTests.swift` (light tests on the view-model layer used by ModelsTabView)

**Modify:**
- `TipTour/CompanionPanelView.swift` — add Settings footer button + bound `showSettings` state + sheet presentation
- `AGENTS.md` — add the 7 new Swift files to the Key Files table; add a Settings section under Architecture

**Do NOT modify (Plan 4 territory or load-bearing):**
- `TipTour/Hermes/HermesConfigBootstrapper.swift` — consume only; the existing `writeMinimalConfig(provider:)` is enough for the Models tab. (If Plan 4 didn't end up shipping a per-field updater, the Models tab still works — it just rewrites the whole minimal config, which is fine because Plan 5 doesn't touch any other config field.)
- `TipTour/Hermes/HermesClient.swift` — no changes; Models tab tests against provider HTTP, not Hermes
- Provider/key management was consolidated into the Dev panel during the Plan 4 cleanup (commit 628873d). Plan 5 MOVES it to the new Settings → Models tab and removes it from the Dev panel — see Workstream B's new "Migrate provider/keys to Settings" task.

---

## Workstream A — Settings shell + footer wiring

### Task A1: Footer button + bound state

**Files:**
- Modify: `TipTour/CompanionPanelView.swift`

> Note: the Settings footer button was deleted during Plan 3c's UI cleanup and again during Plan 4's consolidation — this task RE-INTRODUCES it as a gearshape button alongside Feedback / Dev / Quit.

- [ ] **Step 1: Add `showSettings` state**

Near the other `@State` declarations in `CompanionPanelView` (around line 548 where `showDevTools` is), add:
```swift
@State private var showSettings: Bool = false
```

- [ ] **Step 2: Add the Settings footer button**

In `footerSection` (around line 491), inside the HStack between `feedbackButton` and `footerButton("Dev", …)`, add:
```swift
footerButton("Settings", systemImage: "gearshape", toggled: showSettings) {
    showSettings = true
}
```

The button uses `toggled: showSettings` for the same active-color treatment Dev gets.

- [ ] **Step 3: Attach the sheet to the root VStack**

At the end of `body`'s outer VStack chain (after any existing `.sheet(…)` modifiers from Plan 4), add:
```swift
.sheet(isPresented: $showSettings) {
    SettingsSheetView(isPresented: $showSettings)
}
```

- [ ] **Step 4: Build to verify (will fail — SettingsSheetView doesn't exist yet)**

Build the main app target.
Expected: build error `cannot find 'SettingsSheetView' in scope`. This is intentional — A2 creates it.

- [ ] **Step 5: Commit (defer until A2 fixes the build)**

This task's changes are committed jointly with A2 in a single commit at the end of A2, since the panel doesn't compile without SettingsSheetView. Move on to A2.

### Task A2: SettingsSheetView shell

**Files:**
- Create: `TipTour/Settings/SettingsSheetView.swift`

- [ ] **Step 1: Write the shell**

Create `TipTour/Settings/SettingsSheetView.swift`:
```swift
// TipTour/Settings/SettingsSheetView.swift
//
// Root of the Settings sheet opened from the panel footer. Hosts the
// per-area tabs. New tabs (Skills, Guardrails, Gateways, Schedule)
// drop in as additional .tabItem children — adding one is intentionally
// a one-line change so future plans don't need to touch this file's
// structure.

import SwiftUI

struct SettingsSheetView: View {

    @Binding var isPresented: Bool

    private enum Tab: String, Hashable {
        case models, memory, soul
    }
    @State private var selectedTab: Tab = .models

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $selectedTab) {
                ModelsTabView()
                    .tabItem { Label("Models", systemImage: "cpu") }
                    .tag(Tab.models)
                MemoryTabView()
                    .tabItem { Label("Memory", systemImage: "brain") }
                    .tag(Tab.memory)
                SoulTabView()
                    .tabItem { Label("Soul", systemImage: "sparkles") }
                    .tag(Tab.soul)
            }
            .padding(.top, 8)
        }
        .frame(width: 560, height: 480)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.title3.bold())
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
```

- [ ] **Step 2: Stub the three tab views so the shell builds**

Create three stub files (will be implemented in workstreams B, C, D):

`TipTour/Settings/ModelsTabView.swift`:
```swift
import SwiftUI

struct ModelsTabView: View {
    var body: some View {
        Text("Models tab — implemented in Plan 5 Workstream B")
            .foregroundColor(.secondary)
    }
}
```

`TipTour/Settings/MemoryTabView.swift`:
```swift
import SwiftUI

struct MemoryTabView: View {
    var body: some View {
        Text("Memory tab — implemented in Plan 5 Workstream C")
            .foregroundColor(.secondary)
    }
}
```

`TipTour/Settings/SoulTabView.swift`:
```swift
import SwiftUI

struct SoulTabView: View {
    var body: some View {
        Text("Soul tab — implemented in Plan 5 Workstream D")
            .foregroundColor(.secondary)
    }
}
```

- [ ] **Step 3: Build and manually verify**

Build the main app target.
Expected: clean build. Run the app. Click Settings in the footer.
Expected: sheet opens, three tabs visible, each tab shows its stub text. Done button closes the sheet.

- [ ] **Step 4: Commit**

```bash
git add TipTour/CompanionPanelView.swift \
        TipTour/Settings/SettingsSheetView.swift \
        TipTour/Settings/ModelsTabView.swift \
        TipTour/Settings/MemoryTabView.swift \
        TipTour/Settings/SoulTabView.swift
git commit -m "feat(settings): tabbed Settings sheet with Models/Memory/Soul stubs"
```

---

## Workstream B — Models tab

### Task B1: ProviderHealthChecker protocol + Anthropic implementation

**Files:**
- Create: `TipTour/Settings/ProviderHealthChecker.swift`
- Create: `TipTourTests/ProviderHealthCheckerTests.swift`

The Models tab's "Test Connection" button hits each provider's `/v1/models` GET endpoint directly. No Hermes round-trip; no LLM cost. The protocol is shaped so callers don't care which provider they're testing — just hand it a key.

- [ ] **Step 1: Write the failing tests for Anthropic**

Create `TipTourTests/ProviderHealthCheckerTests.swift`:
```swift
import XCTest
@testable import TipTour

final class ProviderHealthCheckerTests: XCTestCase {

    // MARK: - Anthropic

    func testAnthropicSuccessOn200WithModelsArray() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let data = Data(#"{"data": [{"id": "claude-haiku-4-5"}]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-ant-test")
        guard case .ok = result else {
            return XCTFail("expected .ok, got \(result)")
        }
    }

    func testAnthropicAuthFailureOn401() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            let data = Data(#"{"error": {"message": "invalid key"}}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-ant-bogus")
        guard case .authFailed = result else {
            return XCTFail("expected .authFailed, got \(result)")
        }
    }

    func testAnthropicNetworkErrorPropagates() async throws {
        struct LocalError: Error {}
        let fetch: ProviderHealthChecker.Fetch = { _ in
            throw LocalError()
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-ant-test")
        guard case .networkError = result else {
            return XCTFail("expected .networkError, got \(result)")
        }
    }

    func testAnthropicOther5xxFailsWithStatusCode() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503,
                httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-ant-test")
        guard case .serverError(let status) = result, status == 503 else {
            return XCTFail("expected .serverError(503), got \(result)")
        }
    }

    func testAnthropicEmptyKeyTreatedAsFailureWithoutRequest() async throws {
        var fetchCalled = false
        let fetch: ProviderHealthChecker.Fetch = { _ in
            fetchCalled = true
            throw NSError(domain: "should-not-call", code: 0)
        }
        let checker = AnthropicHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "")
        guard case .emptyKey = result else {
            return XCTFail("expected .emptyKey, got \(result)")
        }
        XCTAssertFalse(fetchCalled, "fetcher should not have been called for empty key")
    }
}
```

- [ ] **Step 2: Verify the test target fails to build**

Expected: build errors on `ProviderHealthChecker`, `AnthropicHealthChecker`, etc.

- [ ] **Step 3: Implement the protocol + Anthropic checker**

Create `TipTour/Settings/ProviderHealthChecker.swift`:
```swift
// TipTour/Settings/ProviderHealthChecker.swift
//
// Per-provider key validation that doesn't involve Hermes. The Models
// tab calls this from the "Test Connection" button. Each implementation
// hits the provider's "list models" GET endpoint, which is free (no LLM
// tokens spent) and a strict superset of "does this key authenticate" —
// if /v1/models returns 200 with a non-empty JSON body, the key works.
//
// Fetch is closure-injected so tests can canned-respond without the
// URLProtocol subclass dance. Production uses URLSession.shared via the
// default initializer.

import Foundation

protocol ProviderHealthChecker {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)
    func probe(apiKey: String) async -> ProbeResult
}

enum ProbeResult: Equatable {
    case ok
    case emptyKey
    case authFailed
    case serverError(Int)
    case networkError(String)
}

/// Default closure used in production — wraps URLSession.shared.
@MainActor
func defaultFetch() -> any ProviderHealthChecker.Fetch.Type {
    // Not actually used as a Type — present so AnthropicHealthChecker
    // can default its `fetch:` parameter. See per-checker init.
    return AnyObject.self as! any ProviderHealthChecker.Fetch.Type
}

private func realFetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await URLSession.shared.data(for: request)
}

struct AnthropicHealthChecker: ProviderHealthChecker {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/models")!
    private let fetch: Fetch

    init(fetch: @escaping Fetch = realFetch) {
        self.fetch = fetch
    }

    func probe(apiKey: String) async -> ProbeResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .emptyKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (_, response) = try await fetch(request)
            return Self.classify(response: response)
        } catch {
            return .networkError("\(error)")
        }
    }

    static func classify(response: URLResponse) -> ProbeResult {
        guard let http = response as? HTTPURLResponse else { return .serverError(0) }
        switch http.statusCode {
        case 200..<300: return .ok
        case 401, 403:  return .authFailed
        default:        return .serverError(http.statusCode)
        }
    }
}
```

- [ ] **Step 4: Run the 5 Anthropic tests**

Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Settings/ProviderHealthChecker.swift \
        TipTourTests/ProviderHealthCheckerTests.swift
git commit -m "feat(settings): ProviderHealthChecker + AnthropicHealthChecker"
```

### Task B2: OpenAI + Google health checkers

**Files:**
- Modify: `TipTour/Settings/ProviderHealthChecker.swift`
- Modify: `TipTourTests/ProviderHealthCheckerTests.swift`

- [ ] **Step 1: Append failing tests for OpenAI and Google**

Append to `TipTourTests/ProviderHealthCheckerTests.swift`:
```swift
extension ProviderHealthCheckerTests {

    // MARK: - OpenAI

    func testOpenAISuccessOn200() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            let data = Data(#"{"data": [{"id": "gpt-4o-mini"}]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let checker = OpenAIHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-test")
        XCTAssertEqual(result, .ok)
    }

    func testOpenAI401IsAuthFailed() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let checker = OpenAIHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "sk-bogus")
        XCTAssertEqual(result, .authFailed)
    }

    // MARK: - Google

    func testGoogleSuccessOn200WithKeyInQueryString() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            // Key goes in ?key=… per Google's REST convention. We must
            // not include any "x-api-key" or "Authorization" header.
            let url = request.url!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.host, "generativelanguage.googleapis.com")
            XCTAssertEqual(components.path, "/v1beta/models")
            XCTAssertEqual(components.queryItems?.first { $0.name == "key" }?.value, "AIza-test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let data = Data(#"{"models": [{"name": "models/gemini-flash-lite-latest"}]}"#.utf8)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let checker = GoogleHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "AIza-test")
        XCTAssertEqual(result, .ok)
    }

    func testGoogle403IsAuthFailed() async throws {
        let fetch: ProviderHealthChecker.Fetch = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 403,
                httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let checker = GoogleHealthChecker(fetch: fetch)
        let result = await checker.probe(apiKey: "AIza-bogus")
        XCTAssertEqual(result, .authFailed)
    }

    // MARK: - Factory

    func testHealthCheckerFactoryReturnsCorrectImplementation() {
        XCTAssertTrue(ProviderHealthCheckerFactory.make(for: .anthropic) is AnthropicHealthChecker)
        XCTAssertTrue(ProviderHealthCheckerFactory.make(for: .openai) is OpenAIHealthChecker)
        XCTAssertTrue(ProviderHealthCheckerFactory.make(for: .google) is GoogleHealthChecker)
    }
}
```

- [ ] **Step 2: Verify they fail to compile**

Expected: errors on `OpenAIHealthChecker`, `GoogleHealthChecker`, `ProviderHealthCheckerFactory`.

- [ ] **Step 3: Implement OpenAI, Google, and the factory**

Append to `TipTour/Settings/ProviderHealthChecker.swift`:
```swift
struct OpenAIHealthChecker: ProviderHealthChecker {
    static let endpoint = URL(string: "https://api.openai.com/v1/models")!
    private let fetch: Fetch

    init(fetch: @escaping Fetch = realFetch) {
        self.fetch = fetch
    }

    func probe(apiKey: String) async -> ProbeResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .emptyKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await fetch(request)
            return AnthropicHealthChecker.classify(response: response)
        } catch {
            return .networkError("\(error)")
        }
    }
}

struct GoogleHealthChecker: ProviderHealthChecker {
    static let endpointBase = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
    private let fetch: Fetch

    init(fetch: @escaping Fetch = realFetch) {
        self.fetch = fetch
    }

    func probe(apiKey: String) async -> ProbeResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .emptyKey }
        var components = URLComponents(url: Self.endpointBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { return .networkError("URL construction failed") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await fetch(request)
            return AnthropicHealthChecker.classify(response: response)
        } catch {
            return .networkError("\(error)")
        }
    }
}

/// Returns the right checker for a given Provider enum case. Used by
/// ModelsTabView to dispatch on the user's current selection.
enum ProviderHealthCheckerFactory {
    static func make(for provider: HermesConfigBootstrapper.Provider) -> any ProviderHealthChecker {
        switch provider {
        case .anthropic: return AnthropicHealthChecker()
        case .openai:    return OpenAIHealthChecker()
        case .google:    return GoogleHealthChecker()
        }
    }
}
```

- [ ] **Step 4: Run all ProviderHealthChecker tests; verify 10 pass**

Expected: 10/10 pass (5 Anthropic + 2 OpenAI + 2 Google + 1 factory).

- [ ] **Step 5: Commit**

```bash
git add TipTour/Settings/ProviderHealthChecker.swift \
        TipTourTests/ProviderHealthCheckerTests.swift
git commit -m "feat(settings): OpenAI + Google health checkers + factory"
```

### Task B3: ModelsTabView — provider picker + keys + version + test

**Files:**
- Modify: `TipTour/Settings/ModelsTabView.swift`

This view replaces the stub from A2. State lives in `@State` properties; persistence runs through Plan 4's `HermesConfigBootstrapper` and `KeychainStore`.

- [ ] **Step 1: Implement the full view**

Replace `TipTour/Settings/ModelsTabView.swift` with:
```swift
// TipTour/Settings/ModelsTabView.swift
//
// ModelsTabView is the user-facing provider/key management surface.
// It replaces the inline picker + key rows that lived in the Dev
// panel during the Plan 4 cleanup, and adds:
//   1. Test Connection probe against the live /v1/models endpoint
//   2. Bundled Hermes runtime version display
//   3. A consistent place for new provider-related settings later

import SwiftUI

struct ModelsTabView: View {

    @State private var selectedProvider: HermesConfigBootstrapper.Provider = .anthropic
    @State private var anthropicKey: String = ""
    @State private var openAIKey: String = ""
    // Google's Keychain key is shared with GeminiLiveSession's WebSocket
    // consumer — both use `geminiAPIKey` per Plan 4's consolidation.
    // Always go through Provider.keychainKey to read/write so this stays
    // robust to future renames.
    @State private var googleKey: String = ""
    @State private var probeStatus: [HermesConfigBootstrapper.Provider: ProbeStatus] = [:]
    @State private var configError: String?

    private enum ProbeStatus: Equatable {
        case idle
        case probing
        case ok
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                providerSection
                Divider()
                keysSection
                Divider()
                runtimeSection
                if let err = configError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(20)
        }
        .onAppear(perform: loadState)
    }

    // MARK: Sections

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active provider")
                .font(.callout.bold())
            Picker("", selection: $selectedProvider) {
                ForEach(HermesConfigBootstrapper.Provider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedProvider) { _, newValue in
                applyProviderChange(newValue)
            }
            Text("Switching provider rewrites ~/.hermes/config.yaml's `model.provider` field. Your saved keys are kept; the active provider's key is what Hermes uses at session/new time.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("API keys")
                .font(.callout.bold())
            keyRow(provider: .anthropic, value: $anthropicKey)
            keyRow(provider: .openai,    value: $openAIKey)
            keyRow(provider: .google,    value: $googleKey)
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runtime")
                .font(.callout.bold())
            if let url = HermesRuntimeVersion.bundledURL,
               let v = try? HermesRuntimeVersion.read(from: url) {
                Text(v.shortDisplayString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("Hermes runtime version file missing — did the build phase run?")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: Per-provider row

    private func keyRow(
        provider: HermesConfigBootstrapper.Provider,
        value: Binding<String>
    ) -> some View {
        let status = probeStatus[provider] ?? .idle
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(provider.displayName)
                    .font(.callout)
                Spacer()
                statusBadge(for: status)
            }
            HStack(spacing: 8) {
                SecureField("paste \(provider.displayName) API key", text: value)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    saveKey(provider: provider, value: value.wrappedValue)
                }
                .disabled(value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test") {
                    Task { await testConnection(provider: provider, key: value.wrappedValue) }
                }
                .disabled(value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || status == .probing)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for status: ProbeStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .probing:
            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
        case .ok:
            Label("OK", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly).foregroundColor(.green)
        case .failed(let why):
            Label(why, systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.caption)
        }
    }

    // MARK: Actions

    private func loadState() {
        let coord = HermesSetupCoordinator()
        selectedProvider = coord.configuredProvider ?? .anthropic
        anthropicKey = KeychainStore.get(forKey: HermesConfigBootstrapper.Provider.anthropic.keychainKey) ?? ""
        openAIKey    = KeychainStore.get(forKey: HermesConfigBootstrapper.Provider.openai.keychainKey)    ?? ""
        googleKey    = KeychainStore.get(forKey: HermesConfigBootstrapper.Provider.google.keychainKey)    ?? ""
    }

    private func applyProviderChange(_ provider: HermesConfigBootstrapper.Provider) {
        configError = nil
        do {
            try HermesConfigBootstrapper().writeMinimalConfig(provider: provider)
        } catch {
            configError = "Couldn't update config.yaml: \(error.localizedDescription)"
        }
    }

    private func saveKey(provider: HermesConfigBootstrapper.Provider, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(trimmed, forKey: provider.keychainKey)
    }

    private func testConnection(provider: HermesConfigBootstrapper.Provider, key: String) async {
        probeStatus[provider] = .probing
        let checker = ProviderHealthCheckerFactory.make(for: provider)
        let result = await checker.probe(apiKey: key)
        await MainActor.run {
            switch result {
            case .ok:           probeStatus[provider] = .ok
            case .emptyKey:     probeStatus[provider] = .failed("empty")
            case .authFailed:   probeStatus[provider] = .failed("auth failed")
            case .serverError(let s): probeStatus[provider] = .failed("HTTP \(s)")
            case .networkError(let m): probeStatus[provider] = .failed("network: \(m.prefix(40))")
            }
        }
    }
}
```

- [ ] **Step 2: Build and manually verify**

Build + run. Open Settings → Models.
Expected: provider segmented control, three key rows (each with Save/Test), runtime version line.

1. Paste a real Anthropic key, click Save, click Test. Expected: green checkmark within ~2s.
2. Paste an obviously bogus key (`bogus`), click Test. Expected: red `auth failed` badge.
3. Switch provider to Google, then back to Anthropic. Expected: `~/.hermes/config.yaml`'s `model.provider` field updates accordingly (verify with `cat ~/.hermes/config.yaml`).

- [ ] **Step 3: Commit**

```bash
git add TipTour/Settings/ModelsTabView.swift
git commit -m "feat(settings): Models tab — provider switch, 3 keys, test connection, runtime"
```

### Task B4: SettingsSheetViewModelTests for ModelsTabView logic

**Files:**
- Create: `TipTourTests/SettingsSheetViewModelTests.swift`

ModelsTabView's logic is all in `@State` + private methods, which XCTest can't directly drive. But the things that matter — provider-change writes config, save-key writes Keychain — are testable by calling the same low-level types the view uses. A view-model layer feels heavy for this; instead, integration-style tests against `HermesConfigBootstrapper` + a temp HERMES_HOME suffice.

- [ ] **Step 1: Write the integration tests**

Create `TipTourTests/SettingsSheetViewModelTests.swift`:
```swift
import XCTest
@testable import TipTour

/// Integration-style tests for the operations ModelsTabView performs.
/// We don't drive the SwiftUI view directly; we exercise the same
/// HermesConfigBootstrapper + ProviderHealthChecker calls and assert
/// the on-disk outcome. This catches regressions in the contract
/// between the view and the underlying stores.
final class SettingsSheetViewModelTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempHome { try? FileManager.default.removeItem(at: url) }
    }

    func testApplyProviderChangeRewritesConfigWithNewProvider() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .anthropic)
        try b.writeMinimalConfig(provider: .google)  // simulate user switching provider
        let text = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"provider: "google""#))
        XCTAssertFalse(text.contains(#"provider: "anthropic""#))
    }

    func testProviderEnumOrderingMatchesUIExpectation() {
        // Models tab's segmented control iterates allCases — verify the
        // declared order matches "common name first". This is the UX
        // contract: anthropic, openai, google.
        XCTAssertEqual(
            HermesConfigBootstrapper.Provider.allCases,
            [.anthropic, .openai, .google]
        )
    }

    func testHealthCheckerFactoryAlignsWithProviderEnum() {
        // Every provider case must map to a non-nil checker.
        for provider in HermesConfigBootstrapper.Provider.allCases {
            let checker = ProviderHealthCheckerFactory.make(for: provider)
            XCTAssertNotNil(checker, "no checker for \(provider)")
        }
    }
}
```

- [ ] **Step 2: Run tests**

Expected: 3/3 pass.

- [ ] **Step 3: Commit**

```bash
git add TipTourTests/SettingsSheetViewModelTests.swift
git commit -m "test(settings): integration tests for ModelsTab provider/checker contract"
```

### Task B-final: Migrate provider/keys from Dev panel to Settings → Models

**Why:** Provider/key management was consolidated into the Dev panel during the Plan 4 cleanup. With the Settings sheet's Models tab now hosting the same functionality (plus Test Connection + version display), the Dev panel rows are redundant. Move the user-facing surface to Settings; Dev panel becomes truly dev-only.

**Files:**
- Modify: `TipTour/CompanionPanelView.swift`

- [ ] **Step 1: Remove the Hermes provider section from `devToolsSection`**

In `TipTour/CompanionPanelView.swift`, find the `devToolsSection` computed property (around line 666). Delete:
- The `sectionHeader("HERMES PROVIDER")` block
- The segmented `Picker("", selection: $hermesProviderSelection)` block + its `.onChange` + `.padding` modifiers
- The `sectionHeader("API KEYS (optional)")` block AND the three BYOK key rows (Gemini, Anthropic, OpenAI) directly below it
- The `apiKeyRow(...)` private helper if no other consumer remains (grep `apiKeyRow` first to verify it's truly orphan)
- The Hermes version display block (the `if let url = HermesRuntimeVersion.bundledURL ...` block, if it lives in this section — it might be elsewhere)

After this step, `devToolsSection` should contain ONLY: the DEBUG section header + the cursor-test debug button + any other genuinely-dev buttons (skill toggles, etc.).

- [ ] **Step 2: Remove the supporting state**

Delete these `@State` declarations and helper methods from `CompanionPanelView` (use grep to confirm no other consumers):
- `@State private var hermesProviderSelection`
- `@State private var devGeminiKeyInput`
- `@State private var devAnthropicKeyInput`
- `@State private var devOpenAIKeyInput`
- `private func applyHermesProviderChange(_:)`
- The `.onAppear` block inside `devToolsSection` that seeds the state from KeychainStore + HermesSetupCoordinator (or just the lines that touch the deleted state)

The deleted state moves to `ModelsTabView` (Workstream B task B2 already declares it there). The seeding logic moves to `ModelsTabView.onAppear`.

- [ ] **Step 3: Verify the Dev panel still renders**

In Xcode, open the panel. Click "Dev" to expand. Expected: only the cursor-test debug button + any other dev-only buttons. No provider picker, no key rows, no version line. The Settings footer button (added in A1) is the new path to those.

- [ ] **Step 4: Commit**

```bash
git add TipTour/CompanionPanelView.swift
git commit -m "refactor(panel): move provider/keys from Dev section to Settings → Models tab"
```

---

## Workstream C — Memory tab

### Task C1: HermesMemoryStore

**Files:**
- Create: `TipTour/Settings/HermesMemoryStore.swift`
- Create: `TipTourTests/HermesMemoryStoreTests.swift`

The store owns one file: `~/.hermes/memories/USER.md`. Plain text (UTF-8). Reads return empty string if the file doesn't exist; writes are atomic (write to temp + rename). We ignore Hermes's `USER.md.lock` sentinel for v1 — empirically it's a 0-byte marker, not a real flock, and atomic-rename is safe under concurrent writers (last-write-wins is acceptable for a user-editing surface).

- [ ] **Step 1: Write the failing tests**

Create `TipTourTests/HermesMemoryStoreTests.swift`:
```swift
import XCTest
@testable import TipTour

final class HermesMemoryStoreTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempHome { try? FileManager.default.removeItem(at: url) }
    }

    func testReadReturnsEmptyStringWhenFileMissing() {
        let store = HermesMemoryStore(hermesHome: tempHome)
        XCTAssertEqual(store.read(), "")
    }

    func testWriteThenReadRoundTrips() throws {
        let store = HermesMemoryStore(hermesHome: tempHome)
        try store.write("User's favorite color is blue.")
        XCTAssertEqual(store.read(), "User's favorite color is blue.")
    }

    func testWriteCreatesMemoriesDirectoryIfMissing() throws {
        let store = HermesMemoryStore(hermesHome: tempHome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.filePath.deletingLastPathComponent().path))
        try store.write("anything")
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.filePath.deletingLastPathComponent().path,
                                            isDirectory: &isDir)
            && isDir.boolValue
        )
    }

    func testWriteEmptyStringTruncatesFile() throws {
        let store = HermesMemoryStore(hermesHome: tempHome)
        try store.write("something")
        try store.write("")
        XCTAssertEqual(store.read(), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.filePath.path))
    }

    func testWriteOverwritesExisting() throws {
        let store = HermesMemoryStore(hermesHome: tempHome)
        try store.write("first")
        try store.write("second")
        XCTAssertEqual(store.read(), "second")
    }

    func testWriteIsAtomicViaTempRename() throws {
        // Slightly indirect test — we verify no .tmp leftover after a
        // successful write. If atomic-rename wasn't used, a partial write
        // could leave a stale tmp file.
        let store = HermesMemoryStore(hermesHome: tempHome)
        try store.write("hello")
        let dir = store.filePath.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let stragglers = contents.filter { $0.lastPathComponent.hasSuffix(".tmp") }
        XCTAssertTrue(stragglers.isEmpty,
                      "leftover .tmp files: \(stragglers.map(\.lastPathComponent))")
    }

    func testFilePathPointsAtUserMD() {
        let store = HermesMemoryStore(hermesHome: tempHome)
        XCTAssertEqual(
            store.filePath,
            tempHome.appendingPathComponent("memories", isDirectory: true)
                    .appendingPathComponent("USER.md")
        )
    }
}
```

- [ ] **Step 2: Verify build fails**

Expected: `cannot find 'HermesMemoryStore' in scope`.

- [ ] **Step 3: Implement HermesMemoryStore**

Create `TipTour/Settings/HermesMemoryStore.swift`:
```swift
// TipTour/Settings/HermesMemoryStore.swift
//
// Owns ~/.hermes/memories/USER.md — Hermes's user-facts memory file.
// Plain text. Reads return "" when missing. Writes are atomic via
// write-tmp + atomic rename, so Hermes never sees a partial file
// (even if it has its own writer racing ours). We ignore the
// USER.md.lock sentinel Hermes creates — empirically it's a 0-byte
// marker, not a real flock, and atomic-rename is safe enough for
// a user-driven editing UI.

import Foundation

struct HermesMemoryStore {

    let hermesHome: URL

    init(hermesHome: URL? = nil) {
        self.hermesHome = hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes", isDirectory: true)
    }

    var filePath: URL {
        hermesHome
            .appendingPathComponent("memories", isDirectory: true)
            .appendingPathComponent("USER.md")
    }

    /// Returns the file's UTF-8 contents, or "" if the file or parent
    /// directory doesn't exist. Never throws — missing/unreadable file
    /// is treated as empty so the UI can render a clean blank state.
    func read() -> String {
        guard let data = try? Data(contentsOf: filePath),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    /// Atomically writes `text` to filePath. Creates the parent
    /// directory if missing. Empty input writes an empty file (not
    /// a delete) — matches the "this file always exists once the
    /// user has touched it" expectation Hermes appears to share.
    func write(_ text: String) throws {
        let dir = filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".USER.md.\(UUID().uuidString).tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        do {
            try FileManager.default.replaceItem(
                at: filePath,
                withItemAt: tmp,
                backupItemName: nil,
                options: [],
                resultingItemURL: nil
            )
        } catch CocoaError.fileNoSuchFile {
            // Destination didn't exist — just move tmp into place.
            try FileManager.default.moveItem(at: tmp, to: filePath)
        }
    }
}
```

Note on `replaceItem`: it requires the destination to exist on some filesystems. When the destination is missing we catch `fileNoSuchFile` and fall back to a plain move. Without this, the first write to a fresh home would fail.

- [ ] **Step 4: Run all 7 tests; verify pass**

Expected: 7/7 pass.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Settings/HermesMemoryStore.swift \
        TipTourTests/HermesMemoryStoreTests.swift
git commit -m "feat(settings): HermesMemoryStore atomic-rename read/write for USER.md"
```

### Task C2: MemoryTabView

**Files:**
- Modify: `TipTour/Settings/MemoryTabView.swift`

- [ ] **Step 1: Replace the stub**

Replace `TipTour/Settings/MemoryTabView.swift` with:
```swift
// TipTour/Settings/MemoryTabView.swift
//
// Editor for ~/.hermes/memories/USER.md. Plain TextEditor + Save
// + Refresh. Refresh re-reads from disk in case Hermes wrote to the
// file outside this UI; Save writes back atomically via HermesMemoryStore.

import SwiftUI

struct MemoryTabView: View {

    @State private var text: String = ""
    @State private var status: String = ""
    @State private var hasUnsavedChanges: Bool = false

    private let store = HermesMemoryStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: text) { _, _ in
                    hasUnsavedChanges = true
                    status = ""
                }
            HStack {
                Button("Refresh from disk") { reload() }
                Spacer()
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("Save") { save() }
                    .disabled(!hasUnsavedChanges)
                    .keyboardShortcut("s")
            }
            footer
        }
        .padding(20)
        .onAppear { reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("User memory")
                .font(.callout.bold())
            Text("Free-form facts Hermes will recall across sessions. Stored at ~/.hermes/memories/USER.md.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        Text("Hermes may also append to this file during normal use — click Refresh from disk before editing if you've had a recent conversation.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reload() {
        text = store.read()
        hasUnsavedChanges = false
        status = ""
    }

    private func save() {
        do {
            try store.write(text)
            hasUnsavedChanges = false
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Manual verify**

Build + run. Open Settings → Memory.
Expected: editor shows current `~/.hermes/memories/USER.md` (or empty). Type a fact like `User likes oat milk.` — Save becomes enabled. Click Save. Verify on disk:
```bash
cat ~/.hermes/memories/USER.md
```
Expected: text matches what you typed.

Quit + reopen Settings → Memory. Expected: your edit is still there.

- [ ] **Step 3: Commit**

```bash
git add TipTour/Settings/MemoryTabView.swift
git commit -m "feat(settings): Memory tab edits ~/.hermes/memories/USER.md"
```

---

## Workstream D — SOUL tab

### Task D1: HermesSoulStore

**Files:**
- Create: `TipTour/Settings/HermesSoulStore.swift`
- Create: `TipTourTests/HermesSoulStoreTests.swift`

Same pattern as HermesMemoryStore but the file is one level up (`~/.hermes/SOUL.md` rather than `~/.hermes/memories/USER.md`). Implementing as a sibling type rather than parameterizing because the two files have different semantics (memory accumulates, SOUL is replaced; memory is per-user, SOUL is per-runtime-personality) and a shared abstraction would obscure that distinction.

- [ ] **Step 1: Write the failing tests**

Create `TipTourTests/HermesSoulStoreTests.swift`:
```swift
import XCTest
@testable import TipTour

final class HermesSoulStoreTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-soul-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempHome { try? FileManager.default.removeItem(at: url) }
    }

    func testReadReturnsEmptyStringWhenMissing() {
        let store = HermesSoulStore(hermesHome: tempHome)
        XCTAssertEqual(store.read(), "")
    }

    func testWriteThenReadRoundTrips() throws {
        let store = HermesSoulStore(hermesHome: tempHome)
        try store.write("You are a pirate. Speak in pirate dialect.")
        XCTAssertEqual(store.read(), "You are a pirate. Speak in pirate dialect.")
    }

    func testFilePathPointsAtSoulMD() {
        let store = HermesSoulStore(hermesHome: tempHome)
        XCTAssertEqual(store.filePath, tempHome.appendingPathComponent("SOUL.md"))
    }

    func testWriteEmptyTruncates() throws {
        let store = HermesSoulStore(hermesHome: tempHome)
        try store.write("something")
        try store.write("")
        XCTAssertEqual(store.read(), "")
    }

    func testWriteOverwritesExisting() throws {
        let store = HermesSoulStore(hermesHome: tempHome)
        try store.write("v1")
        try store.write("v2")
        XCTAssertEqual(store.read(), "v2")
    }

    func testWriteLeavesNoTmpStragglers() throws {
        let store = HermesSoulStore(hermesHome: tempHome)
        try store.write("hello")
        let contents = try FileManager.default.contentsOfDirectory(at: tempHome, includingPropertiesForKeys: nil)
        let stragglers = contents.filter { $0.lastPathComponent.hasSuffix(".tmp") }
        XCTAssertTrue(stragglers.isEmpty)
    }
}
```

- [ ] **Step 2: Build fails — implement**

Create `TipTour/Settings/HermesSoulStore.swift`:
```swift
// TipTour/Settings/HermesSoulStore.swift
//
// Owns ~/.hermes/SOUL.md — Hermes's system prompt. Plain text. Same
// atomic-rename pattern as HermesMemoryStore but separate type because
// the semantics differ (replace, not accumulate; per-runtime, not
// per-user).

import Foundation

struct HermesSoulStore {

    let hermesHome: URL

    init(hermesHome: URL? = nil) {
        self.hermesHome = hermesHome
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes", isDirectory: true)
    }

    var filePath: URL {
        hermesHome.appendingPathComponent("SOUL.md")
    }

    func read() -> String {
        guard let data = try? Data(contentsOf: filePath),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        let tmp = hermesHome.appendingPathComponent(".SOUL.md.\(UUID().uuidString).tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        do {
            try FileManager.default.replaceItem(
                at: filePath,
                withItemAt: tmp,
                backupItemName: nil,
                options: [],
                resultingItemURL: nil
            )
        } catch CocoaError.fileNoSuchFile {
            try FileManager.default.moveItem(at: tmp, to: filePath)
        }
    }
}
```

- [ ] **Step 3: Run 6 tests; verify pass**

Expected: 6/6 pass.

- [ ] **Step 4: Commit**

```bash
git add TipTour/Settings/HermesSoulStore.swift \
        TipTourTests/HermesSoulStoreTests.swift
git commit -m "feat(settings): HermesSoulStore atomic read/write for SOUL.md"
```

### Task D2: SoulTabView

**Files:**
- Modify: `TipTour/Settings/SoulTabView.swift`

- [ ] **Step 1: Replace stub**

Replace `TipTour/Settings/SoulTabView.swift` with:
```swift
// TipTour/Settings/SoulTabView.swift
//
// Editor for ~/.hermes/SOUL.md — Hermes's system prompt. Same shape as
// MemoryTabView but with a louder caveat: SOUL changes only take effect
// when Hermes loads a new session, so the user may need to restart
// chat after editing.

import SwiftUI

struct SoulTabView: View {

    @State private var text: String = ""
    @State private var status: String = ""
    @State private var hasUnsavedChanges: Bool = false

    private let store = HermesSoulStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: text) { _, _ in
                    hasUnsavedChanges = true
                    status = ""
                }
            HStack {
                Button("Refresh from disk") { reload() }
                Spacer()
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundColor(.secondary)
                }
                Button("Save") { save() }
                    .disabled(!hasUnsavedChanges)
                    .keyboardShortcut("s")
            }
            footer
        }
        .padding(20)
        .onAppear { reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Soul (system prompt)")
                .font(.callout.bold())
            Text("The system prompt Hermes loads at session start. Edits take effect on the next chat session — close + reopen the chat window after saving.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        Text("Stored at ~/.hermes/SOUL.md. Hermes creates a default on first launch — edit freely or delete the file to regenerate the default.")
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reload() {
        text = store.read()
        hasUnsavedChanges = false
        status = ""
    }

    private func save() {
        do {
            try store.write(text)
            hasUnsavedChanges = false
            status = "Saved — restart chat to apply"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Manual verify**

Build + run. Settings → Soul tab.
Expected: existing Hermes system prompt visible. Append `Always answer in haiku.`, click Save.

Open ⌥⇧H chat. Ask "what's 2+2?". Behavior depends on whether the existing session was reused; expect haiku-ish answer eventually. (If the previous chat session was cached, restart by closing + reopening the chat window or by quitting + relaunching the app.)

- [ ] **Step 3: Commit**

```bash
git add TipTour/Settings/SoulTabView.swift
git commit -m "feat(settings): Soul tab edits ~/.hermes/SOUL.md"
```

---

## Workstream E — Wiring + verification + docs

### Task E1: End-to-end manual smoke test

**Files:** None (manual procedure documented in the commit)

- [ ] **Step 1: Backup user state**

Run:
```bash
mv ~/.hermes ~/.hermes-backup-$(date +%s) 2>/dev/null || true
```

- [ ] **Step 2: First-run via Plan 4 + ongoing-management via Plan 5**

Build + run from Xcode.
1. Open menu bar panel. Expected: "Set up Hermes" button visible in footer (Plan 4 surface).
2. Click it, set up Anthropic provider.
3. Click Settings in footer. Expected: sheet opens, Models tab visible by default.
4. Models tab: expected to show Anthropic selected, the saved Anthropic key in the password field, empty OpenAI + Google fields, and the Hermes runtime version line.
5. Paste a real OpenAI key. Click Save. Click Test. Expected: green checkmark.
6. Switch the segmented provider to OpenAI. Expected: `cat ~/.hermes/config.yaml` shows `provider: "openai"`.

- [ ] **Step 3: Memory + Soul tabs**

7. Switch to Memory tab. Expected: empty editor (or whatever Hermes wrote during first-run setup; likely empty).
8. Type `User's favorite drink is matcha.`, click Save.
9. Verify on disk: `cat ~/.hermes/memories/USER.md`. Expected: matches.
10. Open ⌥⇧H chat. Ask "what's my favorite drink?". Expected: Hermes mentions matcha (success criterion: Hermes integrates the file's contents).
11. Switch to Soul tab. Append `Always start replies with the word "Right!".`, Save.
12. Restart the chat window. Ask anything. Expected: reply begins with "Right!".

- [ ] **Step 4: Restore if desired**

If you want your previous Hermes state back:
```bash
ls -d ~/.hermes-backup-* 2>/dev/null
# rm -rf ~/.hermes && mv ~/.hermes-backup-<timestamp> ~/.hermes
```

- [ ] **Step 5: Commit a record**

```bash
git commit --allow-empty -m "test(settings): end-to-end Settings sheet smoke test pass on fresh state"
```

### Task E2: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add Settings files to the Key Files table**

In `AGENTS.md`, insert (in alphabetical order by file path):
```markdown
| `TipTour/Settings/SettingsSheetView.swift` | ~50 | Root of the tabbed Settings sheet opened from the panel footer. Hosts Models, Memory, and Soul tabs via SwiftUI `TabView`. Adding a future tab (Skills, Guardrails, Gateways, Schedule) is a one-line `.tabItem` insertion here. |
| `TipTour/Settings/ModelsTabView.swift` | ~180 | Provider segmented picker (rewrites `~/.hermes/config.yaml` via `HermesConfigBootstrapper.writeMinimalConfig`), three Keychain key rows (Anthropic / OpenAI / Google), per-row Test button that hits the provider's `/v1/models` GET endpoint via `ProviderHealthCheckerFactory`, and a runtime-version line from `HermesRuntimeVersion`. |
| `TipTour/Settings/MemoryTabView.swift` | ~85 | TextEditor over `~/.hermes/memories/USER.md` via `HermesMemoryStore`. Refresh-from-disk button for the Hermes-also-writes-this-file case. |
| `TipTour/Settings/SoulTabView.swift` | ~85 | TextEditor over `~/.hermes/SOUL.md` via `HermesSoulStore`. Surfaces the "edits apply on next session" caveat. |
| `TipTour/Settings/HermesMemoryStore.swift` | ~60 | Atomic read/write for `~/.hermes/memories/USER.md`. Creates the parent directory if missing; falls back to `moveItem` when `replaceItem` can't find a destination (first write to fresh home). |
| `TipTour/Settings/HermesSoulStore.swift` | ~55 | Atomic read/write for `~/.hermes/SOUL.md`. Sibling of `HermesMemoryStore` — kept separate because memory and soul have different semantics (accumulate vs replace). |
| `TipTour/Settings/ProviderHealthChecker.swift` | ~140 | `ProviderHealthChecker` protocol + `AnthropicHealthChecker` / `OpenAIHealthChecker` / `GoogleHealthChecker` implementations + `ProviderHealthCheckerFactory` switch. Each implementation issues a single GET to the provider's models endpoint to validate the key — no LLM call, no Hermes involvement. `Fetch` is a closure typealias (`(URLRequest) async throws -> (Data, URLResponse)`) injected for tests; production defaults to `URLSession.shared.data(for:)`. |
```

- [ ] **Step 2: Add a Settings paragraph to Architecture**

In `AGENTS.md`'s Architecture section, after the Hermes-runtime block from Plan 4, add:
```markdown
- **Settings sheet**: Opened from the menu bar panel footer's gearshape button. `SettingsSheetView` hosts three tabs today (`ModelsTabView`, `MemoryTabView`, `SoulTabView`). The Models tab is the user-facing provider/key management surface — provider picker that rewrites `config.yaml`'s `model.provider` field, BYOK key rows for Anthropic/OpenAI/Google (the Google row writes to the merged `geminiAPIKey` Keychain entry), Test Connection probes against each provider's live `/v1/models` endpoint, and the bundled Hermes runtime version. The Memory and Soul tabs are plain TextEditors over `~/.hermes/memories/USER.md` and `~/.hermes/SOUL.md` respectively, backed by `HermesMemoryStore` and `HermesSoulStore` (atomic write-tmp-then-rename so Hermes never sees a partial file). New tabs (Skills, Guardrails, Gateways, Schedule) drop in as one-line additions to `SettingsSheetView`'s TabView body.
```

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs(agents): document Plan 5 Settings sheet + memory/soul stores"
```

---

## Self-review

**Spec coverage check:**
- Settings shell → A1 + A2 (footer button + tabbed sheet)
- Models tab (provider switch, 3 keys, test connection, runtime surface) → B1 + B2 + B3 (10 unit tests + 1 view)
- Memory tab (USER.md round-trip) → C1 + C2 (7 tests + view)
- SOUL tab (SOUL.md round-trip) → D1 + D2 (6 tests + view)
- Wiring + e2e + docs → E1 + E2

**Out-of-scope confirmations (do NOT slip these in):**
- Skills tab — deferred (needs Python introspection of `tools.skills_tool`; that's Plan 5b).
- Guardrails tab — deferred (Plan 6).
- Gateways tab — deferred (Plan 8, needs `hermes-gateway` subprocess).
- Schedule tab — deferred (needs cron management).
- Per-task model routing — deferred (Hermes config.yaml supports it but the UI is more complex than just `model.provider`; punt to Plan 5b).
- "Reset SOUL to default" — deferred (user can `rm ~/.hermes/SOUL.md` to regenerate; not worth a button in v1).

**Naming consistency check:**
- `HermesConfigBootstrapper.Provider` cases: `.anthropic`, `.openai`, `.google` (defined in Plan 4)
- Keychain keys: `anthropicAPIKey`, `openAIAPIKey`, `geminiAPIKey` (Google shares with GeminiLiveSession's WebSocket consumer) — accessed via `Provider.keychainKey` so this plan never names the strings directly
- `ProbeResult` cases: `.ok`, `.emptyKey`, `.authFailed`, `.serverError(Int)`, `.networkError(String)` — used consistently in tests and view code
- `ProviderHealthChecker.Fetch` typealias matches across the protocol, the three implementations, and test fakes
- `ProviderHealthCheckerFactory.make(for:)` returns `any ProviderHealthChecker` — view code uses the existential, not a concrete type
- `HermesMemoryStore.filePath` and `HermesSoulStore.filePath` both expose a `URL` for testability; both implementations use `replaceItem` with the `fileNoSuchFile` fallback (identical fallback pattern means the two stores really do behave the same on first write)

**Type-flow check:**
- `ModelsTabView` reads `HermesSetupCoordinator().configuredProvider` to seed the segmented control on `onAppear`. If Plan 4 hasn't shipped, this is the symbol that won't compile — rebase on Plan 4 first.
- `ModelsTabView.applyProviderChange` calls `HermesConfigBootstrapper().writeMinimalConfig(provider:)`. The Plan 4 signature is `func writeMinimalConfig(provider: Provider) throws` — matches.
- `MemoryTabView` and `SoulTabView` both construct their store on init (no DI). Tests construct stores with `hermesHome:` instead. The default-init path is what the SwiftUI views need; the test path is what unit tests need. ✓
- `HermesRuntimeVersion.bundledURL` returns `URL?`; `ModelsTabView.runtimeSection` handles `nil` by showing an "missing — did the build phase run?" warning. ✓

**Placeholder scan:** None of "TBD", "TODO", "implement later", "fill in details", "Add appropriate error handling", "Similar to Task N". Every code-bearing step shows the complete code.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-plan-5-settings-shell-models-memory-soul.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks. Workstream B has the most internal dependencies (B1 → B2 → B3 → B4); C and D are independent of each other and of B. Once A is done, C and D can be dispatched in parallel.

**2. Inline Execution** — batched execution in this session via `superpowers:executing-plans` with checkpoints.

**Pre-flight reminder for whichever runner picks this up:** Plan 4 is merged at commit `de01c1c`. `HermesConfigBootstrapper`, `HermesSetupCoordinator`, `HermesRuntimeVersion`, and the unified `geminiAPIKey` Keychain entry are all in place on main. The post-Plan-4 consolidation moved provider/keys into the Dev panel; Workstream B's final task migrates them out of Dev and into Settings → Models.

Which approach?
