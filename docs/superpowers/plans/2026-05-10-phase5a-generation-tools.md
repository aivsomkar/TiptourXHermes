# Phase 5A: Generation Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `generate_image` (DALL-E 3 via OpenAI) and `generate_video` (Luma Dream Machine) as first-class agent tools, saving output files to Application Support.

**Architecture:** Two `AgentTool` structs live in a new `GenerationTools.swift` file. They read API keys from the existing `KeychainStore`, call the respective REST APIs, download the result, save it to `~/Library/Application Support/TipTour/generated/`, and return the local file path. `ToolBox.domainTools` for `.imageGeneration` and `.videoGeneration` task types is updated to include these tools. A new `lumaAPIKey` property is added to `KeychainStore` and exposed in the Dev panel BYOK section.

**Tech Stack:** Swift, URLSession, OpenAI Images API (DALL-E 3), Luma Dream Machine API, Swift Testing

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `TipTour/Agents/Tools/GenerationTools.swift` | `GenerateImageTool`, `GenerateVideoTool` |
| Modify | `TipTour/Agents/Tools/AgentTool.swift` | Wire new tools into `ToolBox.domainTools` |
| Modify | `TipTour/KeychainStore.swift` | Add `lumaAPIKey` computed property |
| Modify | `TipTour/CompanionPanelView.swift` | Add Luma + OpenAI BYOK rows in Dev section |
| Create | `TipTourTests/GenerationToolTests.swift` | Unit tests with mock URLSession |

---

## Task 1: `GenerateImageTool`

**Files:**
- Create: `TipTour/Agents/Tools/GenerationTools.swift`
- Test: `TipTourTests/GenerationToolTests.swift`

Background: The OpenAI Images API (`POST https://api.openai.com/v1/images/generations`) generates images from a text prompt. It returns a URL pointing to the generated image. We download that image and save it to disk, returning the file path to the agent.

- [ ] **Step 1: Write the failing test**

Create `TipTourTests/GenerationToolTests.swift`:

```swift
import Testing
import Foundation
@testable import TipTour

@Suite struct GenerationToolTests {

    @Test func generateImageReturnsSavedFilePath() async throws {
        // Build a mock that intercepts /v1/images/generations and
        // returns a fake URL, then intercepts the download and returns
        // 1×1 JPEG bytes.
        MockURLProtocol.stubbedResponses = []
        let fakeImageData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // minimal JPEG header

        // First call: OpenAI Images API → returns JSON with url
        MockURLProtocol.addResponse(
            for: "https://api.openai.com/v1/images/generations",
            data: """
            {"data":[{"url":"https://example.com/image.jpg"}]}
            """.data(using: .utf8)!,
            statusCode: 200
        )
        // Second call: download the image
        MockURLProtocol.addResponse(
            for: "https://example.com/image.jpg",
            data: fakeImageData,
            statusCode: 200
        )

        let tool = GenerateImageTool(
            apiKey: "test-key",
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            urlSession: MockURLProtocol.makeSession()
        )
        let result = await tool.execute(argumentsJSON: """
            {"prompt":"a red apple on a white background"}
            """)
        #expect(result.hasPrefix("/") || result.hasPrefix("~/"))
        #expect(result.hasSuffix(".jpg"))
    }

    @Test func generateImageMissingAPIKeyReturnsError() async {
        let tool = GenerateImageTool(
            apiKey: "",
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            urlSession: URLSession.shared
        )
        let result = await tool.execute(argumentsJSON: """{"prompt":"test"}""")
        #expect(result.hasPrefix("Error:"))
        #expect(result.contains("API key"))
    }

    @Test func generateImageMissingPromptReturnsError() async {
        let tool = GenerateImageTool(
            apiKey: "test-key",
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            urlSession: URLSession.shared
        )
        let result = await tool.execute(argumentsJSON: "{}")
        #expect(result.hasPrefix("Error:"))
        #expect(result.contains("prompt"))
    }
}
```

Add `MockURLProtocol` at the bottom of the test file. Apple's `URLProtocol` is the recommended way to stub URLSession — subclassing `URLSession` doesn't work because `data(for:)` isn't overridable in Swift concurrency.

```swift
// Intercepts URLSession requests and returns canned responses in order.
// Use makeSession() to get a URLSession wired to this protocol.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    // Each entry is consumed once (FIFO) when a matching request arrives.
    static var stubbedResponses: [(urlPrefix: String, data: Data, statusCode: Int)] = []

    static func addResponse(for urlPrefix: String, data: Data, statusCode: Int) {
        stubbedResponses.append((urlPrefix, data, statusCode))
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlString = request.url?.absoluteString ?? ""
        guard let index = Self.stubbedResponses.firstIndex(where: { urlString.hasPrefix($0.urlPrefix) }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = Self.stubbedResponses.remove(at: index)
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.statusCode,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/omkar/Desktop/TipTour-macOS/repo
xcodebuild test -scheme TipTour -only-testing:TipTourTests/GenerationToolTests 2>&1 | grep -E "error:|FAILED|passed|failed" | head -20
```

Expected: compile error — `GenerateImageTool` does not exist yet.

- [ ] **Step 3: Create `GenerationTools.swift` with `GenerateImageTool`**

Create `TipTour/Agents/Tools/GenerationTools.swift`:

```swift
// TipTour/Agents/Tools/GenerationTools.swift

import Foundation

// MARK: - Shared output directory helper

private func generatedOutputDirectory(subpath: String) -> URL {
    let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = appSupport
        .appendingPathComponent("TipTour", isDirectory: true)
        .appendingPathComponent("generated", isDirectory: true)
        .appendingPathComponent(subpath, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func timestampedFilename(extension ext: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    return "\(formatter.string(from: Date())).\(ext)"
}

// MARK: - GenerateImageTool

/// Generates an image from a text prompt using DALL-E 3 (OpenAI Images API).
/// Saves the result as a JPEG to ~/Library/Application Support/TipTour/generated/images/
/// and returns the absolute file path so the agent can open or share the file.
struct GenerateImageTool: AgentTool {

    let name = "generate_image"

    let description = """
        Generate an image from a text prompt using DALL-E 3. \
        Returns the local file path of the saved JPEG. \
        Requires an OpenAI API key configured in Settings.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "A detailed description of the image to generate."
                },
                "size": {
                    "type": "string",
                    "description": "Image dimensions. One of: 1024x1024 (default), 1792x1024, 1024x1792.",
                    "enum": ["1024x1024", "1792x1024", "1024x1792"]
                }
            },
            "required": ["prompt"]
        }
        """

    // Injectable for testing. Production uses KeychainStore + URLSession.shared.
    let apiKey: String
    let outputDirectory: URL
    let urlSession: URLSession

    init(
        apiKey: String = KeychainStore.openAIAPIKey ?? "",
        outputDirectory: URL = generatedOutputDirectory(subpath: "images"),
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.outputDirectory = outputDirectory
        self.urlSession = urlSession
    }

    func execute(argumentsJSON: String) async -> String {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Error: OpenAI API key not configured. Add it in Dev → API KEYS → OpenAI."
        }

        let prompt: String
        let size: String
        do {
            guard let data = argumentsJSON.data(using: .utf8),
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawPrompt = dict["prompt"] as? String, !rawPrompt.isEmpty else {
                throw ToolArgumentError.missingRequiredField("prompt")
            }
            prompt = rawPrompt
            size = dict["size"] as? String ?? "1024x1024"
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        // Step 1: Call DALL-E 3 to get the image URL.
        let imageURL: String
        do {
            imageURL = try await requestImageURL(prompt: prompt, size: size)
        } catch {
            return "Error generating image: \(error.localizedDescription)"
        }

        // Step 2: Download the image.
        let imageData: Data
        do {
            imageData = try await downloadData(from: imageURL)
        } catch {
            return "Error downloading generated image: \(error.localizedDescription)"
        }

        // Step 3: Save to disk and return the path.
        let filename = timestampedFilename(extension: "jpg")
        let fileURL = outputDirectory.appendingPathComponent(filename)
        do {
            try imageData.write(to: fileURL, options: .atomic)
        } catch {
            return "Error saving image to disk: \(error.localizedDescription)"
        }

        return fileURL.path
    }

    private func requestImageURL(prompt: String, size: String) async throws -> String {
        let body: [String: Any] = [
            "model": "dall-e-3",
            "prompt": prompt,
            "n": 1,
            "size": size,
            "response_format": "url"
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 60

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
            throw NSError(domain: "GenerateImage", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI API error: \(body)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let urlString = dataArray.first?["url"] as? String,
              !urlString.isEmpty else {
            throw NSError(domain: "GenerateImage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response format from OpenAI"])
        }
        return urlString
    }

    private func downloadData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GenerateImage", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid image URL: \(urlString)"])
        }
        let request = URLRequest(url: url, timeoutInterval: 60)
        let (data, _) = try await urlSession.data(for: request)
        return data
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme TipTour -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/generateImageReturnsSavedFilePath \
  -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/generateImageMissingAPIKeyReturnsError \
  -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/generateImageMissingPromptReturnsError 2>&1 | grep -E "passed|failed|error:"
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Tools/GenerationTools.swift TipTourTests/GenerationToolTests.swift
git commit -m "feat: add GenerateImageTool using DALL-E 3"
```

---

## Task 2: `GenerateVideoTool`

**Files:**
- Modify: `TipTour/Agents/Tools/GenerationTools.swift`
- Modify: `TipTourTests/GenerationToolTests.swift`

Background: Luma Dream Machine API generates video from text. The flow is async:
1. POST `/dream-machine/v1/generations` → returns `{ "id": "abc123", "state": "queued" }`
2. Poll `GET /dream-machine/v1/generations/abc123` every 5 seconds until `state == "completed"`
3. When done, `assets.video` contains a download URL
4. Download the MP4 and save to disk

- [ ] **Step 1: Write the failing test**

Add to `TipTourTests/GenerationToolTests.swift`:

```swift
@Test func generateVideoReturnsSavedFilePath() async throws {
    MockURLProtocol.stubbedResponses = []
    let fakeVideoData = Data(repeating: 0x00, count: 100)

    // First call: POST to start generation → returns generation ID
    MockURLProtocol.addResponse(
        for: "https://api.lumaai.com/dream-machine/v1/generations",
        data: """
        {"id":"gen-abc123","state":"queued"}
        """.data(using: .utf8)!,
        statusCode: 201
    )
    // Second call: poll for status → returns completed with video URL
    MockURLProtocol.addResponse(
        for: "https://api.lumaai.com/dream-machine/v1/generations/gen-abc123",
        data: """
        {"id":"gen-abc123","state":"completed","assets":{"video":"https://example.com/video.mp4"}}
        """.data(using: .utf8)!,
        statusCode: 200
    )
    // Third call: download the video
    MockURLProtocol.addResponse(
        for: "https://example.com/video.mp4",
        data: fakeVideoData,
        statusCode: 200
    )

    let tool = GenerateVideoTool(
        apiKey: "test-key",
        outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
        urlSession: MockURLProtocol.makeSession(),
        pollIntervalSeconds: 0  // no sleep in tests
    )
    let result = await tool.execute(argumentsJSON: """
        {"prompt":"a golden retriever running on a beach"}
        """)
    #expect(result.hasSuffix(".mp4"))
}

@Test func generateVideoMissingAPIKeyReturnsError() async {
    let tool = GenerateVideoTool(
        apiKey: "",
        outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
        urlSession: URLSession.shared,
        pollIntervalSeconds: 0
    )
    let result = await tool.execute(argumentsJSON: """{"prompt":"test"}""")
    #expect(result.hasPrefix("Error:"))
    #expect(result.contains("Luma"))
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme TipTour -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/generateVideoReturnsSavedFilePath 2>&1 | grep -E "error:|FAILED|compile"
```

Expected: compile error — `GenerateVideoTool` does not exist yet.

- [ ] **Step 3: Add `GenerateVideoTool` to `GenerationTools.swift`**

Append to `TipTour/Agents/Tools/GenerationTools.swift`:

```swift
// MARK: - GenerateVideoTool

/// Generates a video from a text prompt using Luma Dream Machine.
/// Polls until generation completes (up to 10 minutes), downloads the MP4,
/// saves it to ~/Library/Application Support/TipTour/generated/videos/,
/// and returns the absolute file path.
struct GenerateVideoTool: AgentTool {

    let name = "generate_video"

    let description = """
        Generate a short video clip from a text prompt using Luma Dream Machine. \
        Returns the local file path of the saved MP4. Takes 1–5 minutes. \
        Requires a Luma API key configured in Settings.
        """

    let parametersJSON = """
        {
            "type": "object",
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "A detailed description of the video to generate."
                },
                "aspect_ratio": {
                    "type": "string",
                    "description": "Aspect ratio. One of: 16:9 (default), 9:16, 1:1, 4:3.",
                    "enum": ["16:9", "9:16", "1:1", "4:3"]
                }
            },
            "required": ["prompt"]
        }
        """

    let apiKey: String
    let outputDirectory: URL
    let urlSession: URLSession
    let pollIntervalSeconds: TimeInterval
    private let maxPollAttempts = 120   // 120 × 5s = 10 minutes

    init(
        apiKey: String = KeychainStore.lumaAPIKey ?? "",
        outputDirectory: URL = generatedOutputDirectory(subpath: "videos"),
        urlSession: URLSession = .shared,
        pollIntervalSeconds: TimeInterval = 5
    ) {
        self.apiKey = apiKey
        self.outputDirectory = outputDirectory
        self.urlSession = urlSession
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    func execute(argumentsJSON: String) async -> String {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Error: Luma API key not configured. Add it in Dev → API KEYS → Luma."
        }

        let prompt: String
        let aspectRatio: String
        do {
            guard let data = argumentsJSON.data(using: .utf8),
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawPrompt = dict["prompt"] as? String, !rawPrompt.isEmpty else {
                throw ToolArgumentError.missingRequiredField("prompt")
            }
            prompt = rawPrompt
            aspectRatio = dict["aspect_ratio"] as? String ?? "16:9"
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        // Step 1: Submit generation request.
        let generationId: String
        do {
            generationId = try await submitGeneration(prompt: prompt, aspectRatio: aspectRatio)
        } catch {
            return "Error submitting video generation: \(error.localizedDescription)"
        }

        // Step 2: Poll until complete.
        let videoURL: String
        do {
            videoURL = try await pollUntilComplete(generationId: generationId)
        } catch {
            return "Error waiting for video generation: \(error.localizedDescription)"
        }

        // Step 3: Download and save.
        let videoData: Data
        do {
            videoData = try await downloadData(from: videoURL)
        } catch {
            return "Error downloading generated video: \(error.localizedDescription)"
        }

        let filename = timestampedFilename(extension: "mp4")
        let fileURL = outputDirectory.appendingPathComponent(filename)
        do {
            try videoData.write(to: fileURL, options: .atomic)
        } catch {
            return "Error saving video to disk: \(error.localizedDescription)"
        }

        return fileURL.path
    }

    private func submitGeneration(prompt: String, aspectRatio: String) async throws -> String {
        let body: [String: Any] = ["prompt": prompt, "aspect_ratio": aspectRatio, "loop": false]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "https://api.lumaai.com/dream-machine/v1/generations")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 30

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
            throw NSError(domain: "GenerateVideo", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Luma API error: \(body)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else {
            throw NSError(domain: "GenerateVideo", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing generation id in Luma response"])
        }
        return id
    }

    private func pollUntilComplete(generationId: String) async throws -> String {
        var request = URLRequest(
            url: URL(string: "https://api.lumaai.com/dream-machine/v1/generations/\(generationId)")!
        )
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        for _ in 0..<maxPollAttempts {
            if pollIntervalSeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            }

            let (data, _) = try await urlSession.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? String else { continue }

            switch state {
            case "completed":
                guard let assets = json["assets"] as? [String: Any],
                      let videoURLString = assets["video"] as? String,
                      !videoURLString.isEmpty else {
                    throw NSError(domain: "GenerateVideo", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Completed but no video URL in response"])
                }
                return videoURLString

            case "failed":
                let reason = (json["failure_reason"] as? String) ?? "unknown"
                throw NSError(domain: "GenerateVideo", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Generation failed: \(reason)"])

            default:
                // queued or dreaming — keep polling
                continue
            }
        }

        throw NSError(domain: "GenerateVideo", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Video generation timed out after 10 minutes"])
    }

    private func downloadData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GenerateVideo", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid video URL"])
        }
        let (data, _) = try await urlSession.data(for: URLRequest(url: url, timeoutInterval: 300))
        return data
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme TipTour -only-testing:TipTourTests/GenerationToolTests 2>&1 | grep -E "passed|failed|error:" | head -20
```

Expected: 5 passed (3 image + 2 video).

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Tools/GenerationTools.swift TipTourTests/GenerationToolTests.swift
git commit -m "feat: add GenerateVideoTool using Luma Dream Machine"
```

---

## Task 3: Wire Tools into `ToolBox`

**Files:**
- Modify: `TipTour/Agents/Tools/AgentTool.swift:96-114`

The `domainTools(for:)` method currently returns `[RunShellCommandTool()]` for `.imageGeneration` and `.videoGeneration`. Replace with dedicated generation tools plus shell access for the agent to open the file or do post-processing.

- [ ] **Step 1: Write the failing test**

Add to `TipTourTests/GenerationToolTests.swift`:

```swift
@Test func toolBoxImageGenerationIncludesGenerateImageTool() {
    let toolBox = ToolBox.build(for: .imageGeneration)
    let toolNames = toolBox.definitions.map(\.name)
    #expect(toolNames.contains("generate_image"))
    #expect(!toolNames.contains("generate_video"))
}

@Test func toolBoxVideoGenerationIncludesGenerateVideoTool() {
    let toolBox = ToolBox.build(for: .videoGeneration)
    let toolNames = toolBox.definitions.map(\.name)
    #expect(toolNames.contains("generate_video"))
    #expect(!toolNames.contains("generate_image"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/toolBoxImageGenerationIncludesGenerateImageTool \
  -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/toolBoxVideoGenerationIncludesGenerateVideoTool \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: 2 failed — neither tool is in the toolbox yet.

- [ ] **Step 3: Update `ToolBox.domainTools`**

In `TipTour/Agents/Tools/AgentTool.swift`, replace the `imageGeneration, .videoGeneration` case:

```swift
// Replace this:
case .imageGeneration, .videoGeneration:
    // Image/video tasks pass the prompt inline via CLI and receive a file path as output.
    // Shell is sufficient; file I/O is handled by the generation CLI itself.
    return [RunShellCommandTool()]

// With this:
case .imageGeneration:
    return [GenerateImageTool(), RunShellCommandTool()]
case .videoGeneration:
    return [GenerateVideoTool(), RunShellCommandTool()]
```

`RunShellCommandTool` stays so the agent can open the saved file (`open /path/to/image.jpg`) or run post-processing.

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/toolBoxImageGenerationIncludesGenerateImageTool \
  -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/toolBoxVideoGenerationIncludesGenerateVideoTool \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add TipTour/Agents/Tools/AgentTool.swift TipTourTests/GenerationToolTests.swift
git commit -m "feat: wire GenerateImageTool and GenerateVideoTool into ToolBox"
```

---

## Task 4: `lumaAPIKey` in `KeychainStore` + BYOK UI

**Files:**
- Modify: `TipTour/KeychainStore.swift`
- Modify: `TipTour/CompanionPanelView.swift`

The Luma API key needs to be stored in Keychain and editable in the Dev panel alongside the other BYOK keys. While here, also add the missing Anthropic and OpenAI BYOK rows (their keys are already in `KeychainStore` but not shown in the UI).

- [ ] **Step 1: Write the failing test**

Add to `TipTourTests/GenerationToolTests.swift`:

```swift
@Test func keychainStoreExposesLumaAPIKey() {
    // Write, read, clear — verify the lumaAPIKey computed property works.
    KeychainStore.lumaAPIKey = "test-luma-key"
    #expect(KeychainStore.lumaAPIKey == "test-luma-key")
    KeychainStore.lumaAPIKey = nil
    #expect(KeychainStore.lumaAPIKey == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/keychainStoreExposesLumaAPIKey \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: compile error — `KeychainStore.lumaAPIKey` does not exist.

- [ ] **Step 3: Add `lumaAPIKey` to `KeychainStore.swift`**

In `TipTour/KeychainStore.swift`, after the `openAIAPIKey` computed property, add:

```swift
/// Luma AI Dream Machine API key for video generation.
/// Set by the user in TipTour Dev → API KEYS → Luma.
static var lumaAPIKey: String? {
    get { get(forKey: "lumaAPIKey") }
    set { set(newValue ?? "", forKey: "lumaAPIKey") }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
xcodebuild test -scheme TipTour \
  -only-testing:TipTourTests/GenerationToolTests/GenerationToolTests/keychainStoreExposesLumaAPIKey \
  2>&1 | grep -E "passed|failed|error:"
```

Expected: 1 passed.

- [ ] **Step 5: Add BYOK rows to `CompanionPanelView.swift`**

In `TipTour/CompanionPanelView.swift`, locate the `devToolsSection` computed property (the one that already has a `byokKeyRow` for Gemini). Add `@State` properties and BYOK rows for Anthropic, OpenAI, and Luma.

Find the existing `@State private var devGeminiKeyInput: String = ""` block and add after it:

```swift
@State private var devAnthropicKeyInput: String = ""
@State private var devAnthropicKeyStatus: String = ""
@State private var devOpenAIKeyInput: String = ""
@State private var devOpenAIKeyStatus: String = ""
@State private var devLumaKeyInput: String = ""
@State private var devLumaKeyStatus: String = ""
```

Then in `devToolsSection`, after the existing Gemini `byokKeyRow` block (and its status text), add:

```swift
// Anthropic key status
if !devAnthropicKeyStatus.isEmpty {
    Text(devAnthropicKeyStatus)
        .font(.system(size: 10))
        .foregroundColor(DS.Colors.textTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .transition(.opacity)
}

byokKeyRow(
    title: "Anthropic",
    placeholder: "sk-ant-…",
    input: $devAnthropicKeyInput,
    save: { KeychainStore.anthropicAPIKey = devAnthropicKeyInput },
    clear: { devAnthropicKeyInput = ""; KeychainStore.anthropicAPIKey = nil },
    status: $devAnthropicKeyStatus,
    hasSavedKey: !(KeychainStore.anthropicAPIKey ?? "").isEmpty
)

byokKeyRow(
    title: "OpenAI",
    placeholder: "sk-…",
    input: $devOpenAIKeyInput,
    save: { KeychainStore.openAIAPIKey = devOpenAIKeyInput },
    clear: { devOpenAIKeyInput = ""; KeychainStore.openAIAPIKey = nil },
    status: $devOpenAIKeyStatus,
    hasSavedKey: !(KeychainStore.openAIAPIKey ?? "").isEmpty
)
if !devOpenAIKeyStatus.isEmpty {
    Text(devOpenAIKeyStatus)
        .font(.system(size: 10))
        .foregroundColor(DS.Colors.textTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .transition(.opacity)
}

byokKeyRow(
    title: "Luma",
    placeholder: "luma-…",
    input: $devLumaKeyInput,
    save: { KeychainStore.lumaAPIKey = devLumaKeyInput },
    clear: { devLumaKeyInput = ""; KeychainStore.lumaAPIKey = nil },
    status: $devLumaKeyStatus,
    hasSavedKey: !(KeychainStore.lumaAPIKey ?? "").isEmpty
)
if !devLumaKeyStatus.isEmpty {
    Text(devLumaKeyStatus)
        .font(.system(size: 10))
        .foregroundColor(DS.Colors.textTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .transition(.opacity)
}
```

Also add `devAnthropicKeyInput`, `devOpenAIKeyInput`, `devLumaKeyInput` pre-population in the `.onAppear` block:

```swift
devAnthropicKeyInput = KeychainStore.anthropicAPIKey ?? ""
devOpenAIKeyInput = KeychainStore.openAIAPIKey ?? ""
devLumaKeyInput = KeychainStore.lumaAPIKey ?? ""
```

- [ ] **Step 6: Build and verify no compile errors**

```bash
xcodebuild build -scheme TipTour 2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`.

- [ ] **Step 7: Commit**

```bash
git add TipTour/KeychainStore.swift TipTour/CompanionPanelView.swift TipTourTests/GenerationToolTests.swift
git commit -m "feat: add Luma API key to KeychainStore and expose all BYOK rows in Dev panel"
```

---

## Task 5: Full test suite run

- [ ] **Step 1: Run all generation tests**

```bash
xcodebuild test -scheme TipTour -only-testing:TipTourTests/GenerationToolTests 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | head -30
```

Expected: All 7 tests pass.

- [ ] **Step 2: Update CLAUDE.md**

In the Key Files table, update:
- `TipTour/Agents/Tools/AgentTool.swift` line count (was ~125, now ~120 after replacing the comment block)
- Add new row: `TipTour/Agents/Tools/GenerationTools.swift | ~130 | GenerateImageTool (DALL-E 3 via OpenAI) and GenerateVideoTool (Luma Dream Machine). Both save output to ~/Library/Application Support/TipTour/generated/ and return the file path.`
- Update `TipTour/KeychainStore.swift` note to mention `lumaAPIKey`

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for Phase 5A generation tools"
```
