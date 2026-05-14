import XCTest
@testable import TipTour

@MainActor
final class HermesSetupCoordinatorTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempHome {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Pluggable key reader so the test doesn't touch the real Keychain.
    private final class FakeKeyReader: HermesProviderKeyReader {
        var keys: [String: String] = [:]
        func value(forKey key: String) -> String? {
            let v = keys[key]
            return (v?.isEmpty ?? true) ? nil : v
        }
    }

    func testNeedsSetupTrueWhenConfigMissingAndKeyMissing() {
        let reader = FakeKeyReader()
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        XCTAssertTrue(coord.needsSetup)
    }

    func testNeedsSetupTrueWhenConfigPresentButNoMatchingKey() throws {
        let reader = FakeKeyReader()  // no keys
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .anthropic)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        XCTAssertTrue(coord.needsSetup)
    }

    func testNeedsSetupFalseWhenConfigPresentAndMatchingKeyPresent() throws {
        let reader = FakeKeyReader()
        reader.keys["anthropicAPIKey"] = "sk-ant-test"
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .anthropic)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        XCTAssertFalse(coord.needsSetup)
    }

    func testNeedsSetupTrueWhenConfigProviderDiffersFromAvailableKey() throws {
        // Config says google, but only anthropicAPIKey is set in Keychain.
        let reader = FakeKeyReader()
        reader.keys["anthropicAPIKey"] = "sk-ant-test"
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .google)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        XCTAssertTrue(coord.needsSetup)
    }

    func testConfiguredProviderReturnsAnthropic() throws {
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .anthropic)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: FakeKeyReader())
        XCTAssertEqual(coord.configuredProvider, .anthropic)
    }

    func testConfiguredProviderReturnsNilWhenConfigMissing() {
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: FakeKeyReader())
        XCTAssertNil(coord.configuredProvider)
    }

    func testEnvironmentVariablesForSubprocessIncludesConfiguredKey() throws {
        let reader = FakeKeyReader()
        reader.keys["anthropicAPIKey"] = "sk-ant-real"
        let bootstrapper = HermesConfigBootstrapper(hermesHome: tempHome)
        try bootstrapper.writeMinimalConfig(provider: .anthropic)
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: reader)
        let env = coord.environmentVariablesForSubprocess()
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-real")
    }

    func testEnvironmentVariablesForSubprocessEmptyWhenNeedsSetup() {
        let coord = HermesSetupCoordinator(hermesHome: tempHome, keyReader: FakeKeyReader())
        XCTAssertTrue(coord.environmentVariablesForSubprocess().isEmpty)
    }
}
