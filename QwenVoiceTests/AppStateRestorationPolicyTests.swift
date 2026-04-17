import XCTest
@testable import QwenVoice

final class AppStateRestorationPolicyTests: XCTestCase {
    func testDisablesStateRestorationDuringUITestLaunches() {
        XCTAssertFalse(AppStateRestorationPolicy.allowsStateRestoration(isUITestLaunch: true))
    }

    func testAllowsStateRestorationOutsideUITestLaunches() {
        XCTAssertTrue(AppStateRestorationPolicy.allowsStateRestoration(isUITestLaunch: false))
    }
}
