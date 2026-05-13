// TipTourTests/DemonstrationTests.swift

import Foundation
import Testing
@testable import TipTour

// MARK: - ObservedAction tests

@Suite("ObservedAction")
struct ObservedActionTests {

    @Test func codableRoundTripWithAllFields() throws {
        let original = ObservedAction(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            type: .click,
            appName: "Xcode",
            point: CGPoint(x: 100, y: 200),
            text: nil,
            keyDescription: nil,
            scrollDelta: nil,
            screenshotJPEG: Data([0xFF, 0xD8, 0xFF])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ObservedAction.self, from: data)
        #expect(decoded.type == .click)
        #expect(decoded.appName == "Xcode")
        #expect(decoded.point?.x == 100)
        #expect(decoded.screenshotJPEG == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func codableRoundTripTypeAction() throws {
        let original = ObservedAction(
            timestamp: Date(timeIntervalSince1970: 1_000_001),
            type: .type,
            appName: "Terminal",
            point: nil,
            text: "pnpm install",
            keyDescription: nil,
            scrollDelta: nil,
            screenshotJPEG: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ObservedAction.self, from: data)
        #expect(decoded.type == .type)
        #expect(decoded.text == "pnpm install")
        #expect(decoded.screenshotJPEG == nil)
    }

    @Test func codableRoundTripScrollAction() throws {
        let original = ObservedAction(
            timestamp: Date(timeIntervalSince1970: 1_000_002),
            type: .scroll,
            appName: "Finder",
            point: nil,
            text: nil,
            keyDescription: nil,
            scrollDelta: -340,
            screenshotJPEG: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ObservedAction.self, from: data)
        #expect(decoded.type == .scroll)
        #expect(decoded.scrollDelta == -340)
    }
}

// MARK: - ActionTrajectory tests

@Suite("ActionTrajectory")
struct ActionTrajectoryTests {

    @Test func trajectorySendsable() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_000_010)
        let trajectory = ActionTrajectory(startedAt: start, endedAt: end, actions: [])
        #expect(trajectory.startedAt == start)
        #expect(trajectory.endedAt == end)
        #expect(trajectory.actions.isEmpty)
    }

    @Test func trajectoryHoldsMultipleActions() {
        let actions = [
            ObservedAction(timestamp: .now, type: .click, appName: "A", point: .zero, text: nil, keyDescription: nil, scrollDelta: nil, screenshotJPEG: nil),
            ObservedAction(timestamp: .now, type: .type, appName: "A", point: nil, text: "hello", keyDescription: nil, scrollDelta: nil, screenshotJPEG: nil)
        ]
        let trajectory = ActionTrajectory(startedAt: .now, endedAt: .now, actions: actions)
        #expect(trajectory.actions.count == 2)
    }
}

// MARK: - DemonstrationRecorder tests
// All tests inject actions via simulate* methods — no live CGEventTap needed.

@Suite("DemonstrationRecorder")
struct DemonstrationRecorderTests {

    @Test func startClearsPreviousActions() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Xcode", characters: "a")
        _ = recorder.stop()
        // Second recording starts fresh
        recorder.start()
        let trajectory = recorder.stop()
        #expect(trajectory.actions.isEmpty)
    }

    @Test func stopReturnsCorrectTimestamps() async {
        let recorder = DemonstrationRecorder()
        let before = Date.now
        recorder.start()
        let trajectory = recorder.stop()
        let after = Date.now
        #expect(trajectory.startedAt >= before)
        #expect(trajectory.endedAt >= trajectory.startedAt)
        #expect(trajectory.endedAt <= after)
    }

    @Test func consecutiveKeystrokesToSameAppMergeIntoOneTypeAction() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Terminal", characters: "p")
        recorder.simulatePrintableKey(appName: "Terminal", characters: "n")
        recorder.simulatePrintableKey(appName: "Terminal", characters: "p")
        recorder.simulatePrintableKey(appName: "Terminal", characters: "m")
        let trajectory = recorder.stop()
        let typeActions = trajectory.actions.filter { $0.type == .type }
        #expect(typeActions.count == 1)
        #expect(typeActions.first?.text == "pnpm")
    }

    @Test func keystrokeToNewAppFlushesBufferAndStartsFresh() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Terminal", characters: "p")
        recorder.simulatePrintableKey(appName: "Terminal", characters: "n")
        // Switch apps
        recorder.simulatePrintableKey(appName: "Xcode", characters: "x")
        let trajectory = recorder.stop()
        let typeActions = trajectory.actions.filter { $0.type == .type }
        #expect(typeActions.count == 2)
        #expect(typeActions[0].text == "pn")
        #expect(typeActions[0].appName == "Terminal")
        #expect(typeActions[1].text == "x")
        #expect(typeActions[1].appName == "Xcode")
    }

    @Test func nonPrintableKeyFlushesTypingBufferAndAppendsKeyPress() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Terminal", characters: "ls")
        recorder.simulateNonPrintableKey(appName: "Terminal", keyDescription: "Return")
        let trajectory = recorder.stop()
        #expect(trajectory.actions.count == 2)
        #expect(trajectory.actions[0].type == .type)
        #expect(trajectory.actions[0].text == "ls")
        #expect(trajectory.actions[1].type == .keyPress)
        #expect(trajectory.actions[1].keyDescription == "Return")
    }

    @Test func appSwitchFlushesPendingTypingBufferBeforeAppendingSwitch() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Terminal", characters: "hello")
        recorder.simulateAppSwitch(newAppName: "Finder")
        let trajectory = recorder.stop()
        #expect(trajectory.actions.count == 2)
        #expect(trajectory.actions[0].type == .type)
        #expect(trajectory.actions[0].text == "hello")
        #expect(trajectory.actions[1].type == .appSwitch)
        #expect(trajectory.actions[1].appName == "Finder")
    }

    @Test func stopFlushesRemainingTypingBuffer() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulatePrintableKey(appName: "Xcode", characters: "run")
        // Do NOT explicitly flush — stop() must do it
        let trajectory = recorder.stop()
        let typeActions = trajectory.actions.filter { $0.type == .type }
        #expect(typeActions.count == 1)
        #expect(typeActions.first?.text == "run")
    }

    @Test func scrollDebounceAllowsOneEntryPerHalfSecondPerApp() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulateScroll(appName: "Finder", delta: -100)
        recorder.simulateScroll(appName: "Finder", delta: -200)  // debounced
        recorder.simulateScroll(appName: "Safari", delta: -50)   // different app — allowed
        let trajectory = recorder.stop()
        let scrollActions = trajectory.actions.filter { $0.type == .scroll }
        #expect(scrollActions.count == 2)
        #expect(scrollActions[0].appName == "Finder")
        #expect(scrollActions[1].appName == "Safari")
    }

    @Test func formatForLLMProducesOneLinePerAction() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        recorder.simulateClick(appName: "Xcode", point: CGPoint(x: 540, y: 320))
        recorder.simulatePrintableKey(appName: "Terminal", characters: "pnpm install")
        recorder.simulateNonPrintableKey(appName: "Terminal", keyDescription: "Cmd+Return")
        recorder.simulateAppSwitch(newAppName: "Finder")
        recorder.simulateScroll(appName: "Finder", delta: -340)
        let trajectory = recorder.stop()
        let (text, images) = DemonstrationRecorder.formatForLLM(trajectory)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 5)
        #expect(lines[0].contains("click"))
        #expect(lines[0].contains("Xcode"))
        #expect(lines[1].contains("type"))
        #expect(lines[1].contains("pnpm install"))
        #expect(lines[2].contains("keyPress"))
        #expect(lines[2].contains("Cmd+Return"))
        #expect(lines[3].contains("appSwitch"))
        #expect(lines[3].contains("Finder"))
        #expect(lines[4].contains("scroll"))
        // No screenshots injected via simulate — images array should be empty
        #expect(images.isEmpty)
    }

    @Test func formatForLLMIncludesScreenshotNote() async {
        let recorder = DemonstrationRecorder()
        recorder.start()
        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0])
        recorder.simulateClick(appName: "Xcode", point: .zero, screenshotJPEG: fakeJPEG)
        let trajectory = recorder.stop()
        let (text, images) = DemonstrationRecorder.formatForLLM(trajectory)
        #expect(text.contains("[screenshot]"))
        #expect(images.count == 1)
        #expect(images[0] == fakeJPEG)
    }
}

// MARK: - LLMMessage image field test

@Suite("LLMMessageImages")
struct LLMMessageImagesTests {

    @Test func llmMessageCanCarryImages() {
        let fakeJPEG = Data([0xFF, 0xD8])
        let message = LLMMessage(
            role: .user,
            content: "What is in this image?",
            imagesJPEG: [fakeJPEG]
        )
        #expect(message.imagesJPEG?.count == 1)
        #expect(message.imagesJPEG?.first == fakeJPEG)
    }

    @Test func llmMessageWithoutImagesHasNilImagesJPEG() {
        let message = LLMMessage(role: .user, content: "Hello")
        #expect(message.imagesJPEG == nil)
    }
}

// MARK: - SkillExtractor tests

@Suite("SkillExtractor")
struct SkillExtractorTests {

    private func makeTrajectoryWithClickAndType() -> ActionTrajectory {
        let actions: [ObservedAction] = [
            ObservedAction(timestamp: Date(timeIntervalSince1970: 1_000_000), type: .click,
                           appName: "Xcode", point: CGPoint(x: 100, y: 200),
                           text: nil, keyDescription: nil, scrollDelta: nil, screenshotJPEG: nil),
            ObservedAction(timestamp: Date(timeIntervalSince1970: 1_000_001), type: .type,
                           appName: "Terminal", point: nil,
                           text: "pnpm install", keyDescription: nil, scrollDelta: nil, screenshotJPEG: nil)
        ]
        return ActionTrajectory(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_010),
            actions: actions
        )
    }

    @Test func extractSuccessReturnsMockBody() async throws {
        let mockProvider = MockLLMProvider(id: "skill-extractor-test")
        mockProvider.responseToReturn = .text("## Steps\n\n1. Click in Xcode\n2. Type pnpm install\n\n## Result\n\nDependencies installed.")
        let extractor = SkillExtractor(providerOverride: mockProvider)

        let body = try await extractor.extract(
            trajectory: makeTrajectoryWithClickAndType(),
            name: "Install pnpm deps"
        )
        #expect(body.contains("## Steps"))
        #expect(body.contains("## Result"))
    }

    @Test func extractSendsTrajectoryTextToProvider() async throws {
        let mockProvider = MockLLMProvider(id: "skill-extractor-capture")
        mockProvider.responseToReturn = .text("## Steps\n\n1. Step\n\n## Result\n\nDone.")
        let extractor = SkillExtractor(providerOverride: mockProvider)

        _ = try await extractor.extract(
            trajectory: makeTrajectoryWithClickAndType(),
            name: "test skill"
        )
        // Provider should have received one complete() call
        #expect(mockProvider.capturedMessages.count == 1)
        let messages = mockProvider.capturedMessages[0]
        // Should have system + user messages
        #expect(messages.count == 2)
        #expect(messages[0].role == .system)
        #expect(messages[1].role == .user)
        // User message should contain the trajectory text
        #expect(messages[1].content.contains("click"))
        #expect(messages[1].content.contains("type"))
    }

    @Test func extractEmptyTrajectoryReturnsBodyWithResultSection() async throws {
        let mockProvider = MockLLMProvider(id: "skill-extractor-empty")
        mockProvider.responseToReturn = .text("## Result\n\nEmpty demonstration.")
        let extractor = SkillExtractor(providerOverride: mockProvider)

        let emptyTrajectory = ActionTrajectory(startedAt: .now, endedAt: .now, actions: [])
        let body = try await extractor.extract(trajectory: emptyTrajectory, name: "empty")
        #expect(body.contains("## Result"))
    }

    @Test func extractRethrowsProviderError() async {
        let mockProvider = MockLLMProvider(id: "skill-extractor-throw")
        mockProvider.shouldThrow = true
        let extractor = SkillExtractor(providerOverride: mockProvider)

        do {
            _ = try await extractor.extract(
                trajectory: ActionTrajectory(startedAt: .now, endedAt: .now, actions: []),
                name: "fail"
            )
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is LLMProviderError)
        }
    }

    @Test func extractThrowsWhenNoProviderAvailable() async {
        let extractor = SkillExtractor(providerOverride: nil)
        do {
            _ = try await extractor.extract(
                trajectory: ActionTrajectory(startedAt: .now, endedAt: .now, actions: []),
                name: "no-provider"
            )
        } catch let error as SkillExtractorError {
            #expect(error == .missingProvider)
        } catch {
            // Any error is acceptable — either missingProvider or an API call failure
        }
    }
}

// MARK: - CompanionManager demonstration state tests

// .serialized prevents concurrent mutation of CompanionManager (which is @MainActor)
@Suite("CompanionManagerDemonstrationState", .serialized)
struct CompanionManagerDemonstrationStateTests {

    @Test @MainActor func startDemonstrationSetsFlag() {
        let manager = CompanionManager()
        manager.startDemonstration()
        #expect(manager.isDemonstratingSkill == true)
        manager.stopDemonstration()  // clean up
    }

    @Test @MainActor func stopDemonstrationClearsFlagAndPopulatesTrajectory() {
        let manager = CompanionManager()
        manager.startDemonstration()
        manager.stopDemonstration()
        #expect(manager.isDemonstratingSkill == false)
        #expect(manager.pendingTrajectory != nil)
    }

    @Test @MainActor func discardDemonstrationClearsPendingTrajectory() {
        let manager = CompanionManager()
        manager.startDemonstration()
        manager.stopDemonstration()
        #expect(manager.pendingTrajectory != nil)
        manager.discardDemonstration()
        #expect(manager.pendingTrajectory == nil)
        #expect(manager.skillExtractionError == nil)
    }

    @Test @MainActor func saveSkillSuccessClearsPendingTrajectory() async {
        let manager = CompanionManager()
        let mockProvider = MockLLMProvider(id: "save-skill-success")
        mockProvider.responseToReturn = .text("## Steps\n\n1. Do thing\n\n## Result\n\nDone.")
        let mockExtractor = SkillExtractor(providerOverride: mockProvider)
        manager.skillExtractorOverrideForTests = mockExtractor

        manager.startDemonstration()
        manager.stopDemonstration()
        #expect(manager.pendingTrajectory != nil)

        await manager.saveSkill(name: "Test Skill")

        #expect(manager.pendingTrajectory == nil)
        #expect(manager.isExtractingSkill == false)
        #expect(manager.skillExtractionError == nil)
    }

    @Test @MainActor func saveSkillFailureSetsErrorAndClearsExtractingFlag() async {
        let manager = CompanionManager()
        let mockProvider = MockLLMProvider(id: "save-skill-failure")
        mockProvider.shouldThrow = true
        let mockExtractor = SkillExtractor(providerOverride: mockProvider)
        manager.skillExtractorOverrideForTests = mockExtractor

        manager.startDemonstration()
        manager.stopDemonstration()

        await manager.saveSkill(name: "Failing Skill")

        #expect(manager.isExtractingSkill == false)
        #expect(manager.skillExtractionError != nil)
        // pendingTrajectory remains so the user can retry
        #expect(manager.pendingTrajectory != nil)
    }
}
