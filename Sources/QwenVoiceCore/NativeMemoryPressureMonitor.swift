import Foundation

/// Defines the ordering required when the kernel asks the native runtime to
/// shed memory.
///
/// A warning-level soft trim only clears reclaimable caches. It intentionally
/// does not interrupt useful generation work. A critical hard trim can clear
/// state that an in-flight generation is still using, so it must first cancel
/// that generation with the typed memory-pressure reason and wait for its
/// terminal barrier. `fullUnload` is not emitted by
/// `NativeMemoryPressureMonitor` and retains its existing caller-owned policy.
struct NativeMemoryPressureResponsePolicy: Sendable {
    enum Preparation: Equatable, Sendable {
        case none
        case cancelActiveGeneration(GenerationCancellationReason)
    }

    func preparation(before level: NativeMemoryTrimLevel) -> Preparation {
        switch level {
        case .softTrim, .fullUnload:
            return .none
        case .hardTrim:
            return .cancelActiveGeneration(.memoryPressure)
        }
    }
}

/// Serializes kernel-pressure responses and makes their side effects
/// injectable for deterministic tests.
///
/// The cancellation handler is the terminal barrier: it must not return until
/// the registered generation task has actually stopped. Consequently the trim
/// handler can never run concurrently with active model compute for a critical
/// event.
actor NativeMemoryPressureResponseExecutor {
    typealias ObservationHandler = @Sendable (NativeMemoryTrimLevel) async -> Void
    typealias CancellationHandler = @Sendable (GenerationCancellationReason) async -> Void
    typealias TrimHandler = @Sendable (NativeMemoryTrimLevel, String) async -> Void

    private let policy: NativeMemoryPressureResponsePolicy
    private let recordObservation: ObservationHandler
    private let cancelActiveGeneration: CancellationHandler
    private let trim: TrimHandler
    private var responseInFlight = false
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        policy: NativeMemoryPressureResponsePolicy = NativeMemoryPressureResponsePolicy(),
        recordObservation: @escaping ObservationHandler,
        cancelActiveGeneration: @escaping CancellationHandler,
        trim: @escaping TrimHandler
    ) {
        self.policy = policy
        self.recordObservation = recordObservation
        self.cancelActiveGeneration = cancelActiveGeneration
        self.trim = trim
    }

    func execute(level: NativeMemoryTrimLevel, reason: String) async {
        await acquireResponseSlot()
        defer { releaseResponseSlot() }

        // Preserve the raw signal even if cancellation takes long enough that
        // the later trim mark misses the active generation's telemetry window.
        await recordObservation(level)

        switch policy.preparation(before: level) {
        case .none:
            break
        case .cancelActiveGeneration(let cancellationReason):
            await cancelActiveGeneration(cancellationReason)
        }

        await trim(level, reason)
    }

    private func acquireResponseSlot() async {
        guard responseInFlight else {
            responseInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            responseWaiters.append(continuation)
        }
    }

    private func releaseResponseSlot() {
        guard !responseWaiters.isEmpty else {
            responseInFlight = false
            return
        }
        let next = responseWaiters.removeFirst()
        next.resume()
    }
}

/// Subscribes to kernel memory-pressure events and publishes the translated
/// `NativeMemoryTrimLevel` to interested consumers. macOS uses it for the
/// XPC engine process on 8 GB and 16 GB Macs; iOS uses it in the app process
/// (the engine runs in-process) so MLX can shed cache based on kernel pressure
/// events.
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

    #if os(macOS) || os(iOS)
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
    /// `start()` while already started is a no-op.
    public func start() {
        #if os(macOS) || os(iOS)
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
        #if os(macOS) || os(iOS)
        queue.async { [weak self] in
            guard let self else { return }
            self.source?.cancel()
            self.source = nil
        }
        #endif
        continuation.finish()
    }

    #if os(macOS) || os(iOS)
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
