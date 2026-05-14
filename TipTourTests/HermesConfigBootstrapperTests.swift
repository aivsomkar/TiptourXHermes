import XCTest
@testable import TipTour

final class HermesConfigBootstrapperTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = try makeTempHome()
    }

    override func tearDownWithError() throws {
        if let url = tempHome,
           FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeTempHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-bootstrapper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: hasValidConfig

    func testHasValidConfigReturnsFalseWhenFileMissing() {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        XCTAssertFalse(b.hasValidConfig)
    }

    func testHasValidConfigReturnsTrueAfterWritingMinimalConfig() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .anthropic)
        XCTAssertTrue(b.hasValidConfig)
    }

    func testHasValidConfigReturnsFalseForEmptyFile() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try "".write(to: b.configPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(b.hasValidConfig)
    }

    func testHasValidConfigReturnsFalseForConfigMissingModelKey() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try "irrelevant: value\n".write(to: b.configPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(b.hasValidConfig)
    }

    // MARK: writeMinimalConfig

    func testWriteMinimalConfigForAnthropicEmitsExpectedYAML() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .anthropic)
        let text = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"default: "anthropic/claude-haiku-4-5""#))
        XCTAssertTrue(text.contains(#"provider: "anthropic""#))
    }

    func testWriteMinimalConfigForGoogleEmitsExpectedYAML() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .google)
        let text = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"default: "google/gemini-flash-lite-latest""#))
        XCTAssertTrue(text.contains(#"provider: "google""#))
    }

    func testWriteMinimalConfigForOpenAIEmitsExpectedYAML() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .openai)
        let text = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"default: "openai/gpt-4o-mini""#))
        XCTAssertTrue(text.contains(#"provider: "openai""#))
    }

    func testWriteMinimalConfigIsIdempotent() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .anthropic)
        let first = try String(contentsOf: b.configPath, encoding: .utf8)
        try b.writeMinimalConfig(provider: .anthropic)
        let second = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertEqual(first, second)
    }

    func testWriteMinimalConfigCreatesHermesHomeDirectory() throws {
        let nested = tempHome.appendingPathComponent("nested-fresh-home", isDirectory: true)
        let b = HermesConfigBootstrapper(hermesHome: nested)
        try b.writeMinimalConfig(provider: .anthropic)
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDir)
            && isDir.boolValue
        )
    }

    func testWriteMinimalConfigOverwritesExistingFile() throws {
        let b = HermesConfigBootstrapper(hermesHome: tempHome)
        try b.writeMinimalConfig(provider: .anthropic)
        try b.writeMinimalConfig(provider: .google)
        let text = try String(contentsOf: b.configPath, encoding: .utf8)
        XCTAssertTrue(text.contains(#"provider: "google""#))
        XCTAssertFalse(text.contains(#"provider: "anthropic""#))
    }

    // MARK: provider enum

    func testProviderEnvVarMatchesHermesExpectation() {
        XCTAssertEqual(HermesConfigBootstrapper.Provider.anthropic.environmentVariable, "ANTHROPIC_API_KEY")
        XCTAssertEqual(HermesConfigBootstrapper.Provider.openai.environmentVariable, "OPENAI_API_KEY")
        XCTAssertEqual(HermesConfigBootstrapper.Provider.google.environmentVariable, "GEMINI_API_KEY")
    }
}
