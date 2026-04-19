import Foundation
import UIKit

@MainActor
enum IOSModelDeliveryBackgroundEventRelay {
    static var handler: ((@escaping () -> Void) -> Void)?
    private static var pendingCompletionHandler: (() -> Void)?

    static func store(_ completionHandler: @escaping () -> Void) {
        pendingCompletionHandler = completionHandler
    }

    static func completeIfPending() {
        pendingCompletionHandler?()
        pendingCompletionHandler = nil
    }
}

final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if let handler = IOSModelDeliveryBackgroundEventRelay.handler {
                handler(completionHandler)
            } else {
                // Handler not registered yet — stash for later. The delivery
                // actor will call completeIfPending() once it reconnects.
                IOSModelDeliveryBackgroundEventRelay.store(completionHandler)
            }
        }
    }
}
