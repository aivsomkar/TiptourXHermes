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
