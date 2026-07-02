import CallKit
import Foundation
import UIKit

/// Records run-dooming interruptions during headless on-device runs: phone calls
/// (`CXCallObserver` — no special entitlement) and app lifecycle transitions (the
/// user unlocking/using the phone backgrounds the app under test).
///
/// **Runtime-gated, ships inert**: started only by `IOSAutorunHarness` (which
/// itself fires only when `QVOICE_IOS_AUTORUN` is set by `scripts/ios_device.sh`).
/// A normal user launch never creates it. Follows the repo's runtime-gate
/// philosophy — no `#if DEBUG`.
///
/// Consumers: the autorun sentinel (`autorun-done.json` gains `interruptions`)
/// so `ios_device.sh bench`/`gate` can report "failed because a call arrived at
/// t=42s" instead of a generic timeout.
@MainActor
public final class IOSInterruptionRecorder: NSObject {
    public struct Event: Codable, Sendable {
        public let type: String
        /// Milliseconds since the recorder started (≈ run start).
        public let atMS: Int
        public let recordedAt: String
    }

    public static let shared = IOSInterruptionRecorder()

    private var callObserver: CXCallObserver?
    private var notificationTokens: [NSObjectProtocol] = []
    private var startedAt: Date?
    private var events: [Event] = []
    private let dateFormatter = ISO8601DateFormatter()

    override private init() {
        super.init()
    }

    /// Idempotent. Call once at the start of a monitored run.
    public func start() {
        guard startedAt == nil else { return }
        startedAt = Date()

        let observer = CXCallObserver()
        observer.setDelegate(self, queue: .main)
        callObserver = observer

        let center = NotificationCenter.default
        let lifecycle: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "will_resign_active"),
            (UIApplication.didEnterBackgroundNotification, "did_enter_background"),
            (UIApplication.didBecomeActiveNotification, "did_become_active"),
        ]
        for (name, label) in lifecycle {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.record(type: label)
                }
            }
            notificationTokens.append(token)
        }
        print("[interruptions] recorder started")
    }

    /// Events observed so far (for the autorun sentinel).
    public func snapshot() -> [Event] {
        events
    }

    private func record(type: String) {
        guard let startedAt else { return }
        let event = Event(
            type: type,
            atMS: Int(Date().timeIntervalSince(startedAt) * 1000),
            recordedAt: dateFormatter.string(from: Date())
        )
        events.append(event)
        print("[interruptions] \(event.type) at t=\(event.atMS)ms")
    }
}

extension IOSInterruptionRecorder: CXCallObserverDelegate {
    public nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let type: String
        if call.hasEnded {
            type = "call_ended"
        } else if call.hasConnected {
            type = "call_connected"
        } else if call.isOutgoing {
            type = "call_outgoing"
        } else {
            type = "call_incoming"
        }
        Task { @MainActor in
            IOSInterruptionRecorder.shared.record(type: type)
        }
    }
}
