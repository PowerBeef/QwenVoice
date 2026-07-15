import Foundation
import UIKit

/// Relays iOS background-URLSession completion handlers for the exact session owned by this app
/// process. The app delegate stashes each accepted handler here (keyed by the session id from
/// `handleEventsForBackgroundURLSession`); the in-flight `HuggingFaceDownloader` flushes its own
/// session's handler from `urlSessionDidFinishEvents(forBackgroundURLSession:)` when that session
/// finishes all events. Canonical and debug-isolated delivery sessions must never complete or
/// retain one another's handlers. An owned handler with no durable work is completed explicitly
/// after restore/resume reconciliation.
@MainActor
enum IOSModelDeliveryBackgroundEventRelay {
    /// Registered by the app bootstrap: routes a `(identifier, completionHandler)` pair into the
    /// installer. Set once at launch; the app delegate invokes it when the system delivers a
    /// background event.
    static var handler: ((String, @escaping () -> Void) -> Void)?

    private static let pendingHandlers = IOSModelDeliveryBackgroundEventHandlerStore()

    @discardableResult
    static func store(
        _ completionHandler: @escaping () -> Void,
        forSessionIdentifier identifier: String,
        ownedSessionIdentifier: String
    ) -> Bool {
        pendingHandlers.store(
            completionHandler,
            forDeliveredSessionIdentifier: identifier,
            ownedSessionIdentifier: ownedSessionIdentifier
        )
    }

    /// Called by a downloader's `urlSessionDidFinishEvents` hook when its background session has
    /// finished delivering all events.
    static func complete(forOwnedSessionIdentifier identifier: String) {
        pendingHandlers.completeOwnedSession(identifier)
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
                handler(identifier, completionHandler)
            } else {
                // Handler not registered yet — retain this callback only when it belongs to the
                // current canonical or debug-isolated delivery namespace. The coordinator flushes
                // an owned no-work callback once durable reconciliation finishes.
                let ownedIdentifier = IOSModelDeliveryConfiguration.default()
                    .backgroundSessionIdentifier
                IOSModelDeliveryBackgroundEventRelay.store(
                    completionHandler,
                    forSessionIdentifier: identifier,
                    ownedSessionIdentifier: ownedIdentifier
                )
            }
        }
    }
}
