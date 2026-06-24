import XCTest

/// Releases the warm `XCUIApplication` session when a device-safe UI test run finishes.
final class VocelloUITestObserver: NSObject, XCTestObservation, @unchecked Sendable {
    static let shared = VocelloUITestObserver()

    private override init() {
        super.init()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        VocelloUITestApp.shared.release()
    }
}

private enum VocelloUITestObserverRegistration {
    static let token: Void = {
        XCTestObservationCenter.shared.addTestObserver(VocelloUITestObserver.shared)
    }()
}

/// Ensures the observer is registered when the first warm suite starts.
enum VocelloUITestBootstrap {
    static func registerObserverIfNeeded() {
        _ = VocelloUITestObserverRegistration.token
    }
}
