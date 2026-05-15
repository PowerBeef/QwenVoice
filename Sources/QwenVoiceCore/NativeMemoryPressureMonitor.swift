import Foundation

/// Subscribes to kernel memory-pressure events on macOS and publishes the
/// translated `NativeMemoryTrimLevel` to interested consumers. The iOS
/// runtime has its own (heavier) monitor in
/// `Sources/iOS/IOSShellPrimitives.swift` keyed off
/// `DispatchSource.makeMemoryPressureSource` *and*
/// `UIApplication.didReceiveMemoryWarningNotification`; this type covers the
/// macOS half so 8 GB and 16 GB Macs get the same dynamic-trim behavior
/// iPhone has had.
///
/// Mapping from kernel pressure event to trim level:
///
/// - `.warning` → `.softTrim`   (clear MLX cache + clone soft-trim)
/// - `.critical` → `.hardTrim`  (clear everything resident in the runtime)
/// - `.normal` → no trim, just transition back to a "healthy" state
///
/// Why this is a class, not an actor: `DispatchSource` callbacks fire on
/// the dispatch queue, which is fine since this class only mutates a single
/// `currentLevel` field and forwards events to an `AsyncStream`. The class
/// is `@unchecked Sendable` because all mutation goes through the dispatch
/// queue.
///
/// **macOS only.** On iOS the existing `IOSShellPrimitives` infrastructure
/// is canonical; this type compiles to a no-op there so call sites can
/// reference it unconditionally.
public final class NativeMemoryPressureMonitor: @unchecked Sendable {
    /// The most recent trim level dispatched by this monitor, or `nil` if
    /// the system has been in the "normal" band since the monitor started.
    /// Reads of this property are eventually-consistent: the writer is the
    /// dispatch queue, readers are typically the engine on its own queue.
    public private(set) var currentLevel: NativeMemoryTrimLevel?

    /// Push-notification stream. Each event corresponds to a trim level the
    /// engine should act on. A `.normal` system transition does NOT emit an
    /// event — there's no work to do when pressure drops.
    public let events: AsyncStream<NativeMemoryTrimLevel>

    private let continuation: AsyncStream<NativeMemoryTrimLevel>.Continuation
    private let queue: DispatchQueue

    #if os(macOS)
    private var source: (any DispatchSourceMemoryPressure)?
    #endif

    public init(label: String = "com.qwenvoice.engine.memory-pressure") {
        self.queue = DispatchQueue(label: label, qos: .utility)
        var capturedContinuation: AsyncStream<NativeMemoryTrimLevel>.Continuation!
        self.events = AsyncStream<NativeMemoryTrimLevel> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    /// Begin listening for memory-pressure events. Idempotent — calling
    /// `start()` while already started is a no-op. On iOS this is a no-op
    /// because the iOS host has its own monitor and we don't want two
    /// subscribers competing.
    public func start() {
        #if os(macOS)
        queue.async { [weak self] in
            guard let self else { return }
            guard self.source == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical],
                queue: self.queue
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                self.handle(event: source.data)
            }
            source.resume()
            self.source = source
        }
        #endif
    }

    /// Stop listening and finish the `events` stream. After `stop()` the
    /// monitor cannot be restarted — create a new instance instead.
    public func stop() {
        #if os(macOS)
        queue.async { [weak self] in
            guard let self else { return }
            self.source?.cancel()
            self.source = nil
        }
        #endif
        continuation.finish()
    }

    #if os(macOS)
    private func handle(event: DispatchSource.MemoryPressureEvent) {
        // The DispatchSource event mask can deliver multiple flags in one
        // callback (e.g. .warning + .critical). Treat .critical as winning
        // since it implies harder action; .warning maps to soft trim;
        // .normal clears the local level back to nil but does not emit
        // (callers should react to *pressure*, not pressure-relief).
        if event.contains(.critical) {
            transition(to: .hardTrim, emit: true)
        } else if event.contains(.warning) {
            transition(to: .softTrim, emit: true)
        } else if event.contains(.normal) {
            transition(to: nil, emit: false)
        }
    }

    private func transition(to level: NativeMemoryTrimLevel?, emit: Bool) {
        let previous = currentLevel
        currentLevel = level
        guard emit, let level, previous != level else { return }
        continuation.yield(level)
    }
    #endif
}
