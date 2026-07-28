import SwiftUI
import XCTest
@testable import Noctweave_Relay

final class NoctweaveAppearanceTests: XCTestCase {
    func testAppearanceModesMapToExpectedColorSchemes() {
        XCTAssertNil(NoctweaveAppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(NoctweaveAppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(NoctweaveAppearanceMode.dark.preferredColorScheme, .dark)
    }

    func testThemeTokensResolveDistinctModes() {
        let light = NoctweaveThemeTokens(colorScheme: .light)
        let dark = NoctweaveThemeTokens(colorScheme: .dark)

        XCTAssertFalse(light.isDark)
        XCTAssertTrue(dark.isDark)
        XCTAssertNotEqual(light.canvas, dark.canvas)
        XCTAssertNotEqual(light.surfaceRaised, dark.surfaceRaised)
        XCTAssertNotEqual(light.selectedText, dark.selectedText)
    }
}
