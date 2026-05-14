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
