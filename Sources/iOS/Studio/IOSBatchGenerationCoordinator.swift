import SwiftUI
import QwenVoiceCore

/// Runs a multi-line script as a batch of per-line takes on iOS (parity with the
/// macOS BatchGenerationRunner / GitHub #30). iOS-specific shape:
///
/// - **Streaming, not the macOS non-streaming generateBatch.** iOS must stream
///   each item (`shouldStream: true`) so the per-item peak stays flat (~3 GB);
///   the non-streaming path accumulates the whole clip (~7.6 GB) and would
///   Jetsam-kill (see docs/reference/ios-engine-optimization.md). The model
///   stays warm across the sequential items (30 s idle-unload), so it is
///   effectively one load.
/// - **Headless.** It toggles `AudioPlayerViewModel.batchSuppression` so streamed
///   chunks are dropped (no per-item live playback). The dropped chunks carry no
///   files to clean up (NativeStreamingOutputPolicy defaults to `.pcmPreview`).
/// - **One shared seed** across the batch so it reproduces as a unit.
///
/// Mode-specific request/record building is injected by the caller, so this is
/// reusable for Custom Voice and Voice Design (Voice Cloning is single-reference
/// and is not batched).
@MainActor
final class IOSBatchGenerationCoordinator: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let index: Int
        let text: String
        var status: Status = .pending

        enum Status: Equatable {
            case pending
            case generating
            case done(duration: Double)
            case failed(String)
            case cancelled
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0

    private var task: Task<Void, Never>?

    var total: Int { items.count }
    var progress: Double { total == 0 ? 0 : Double(completedCount) / Double(total) }
    var didFinish: Bool { !isRunning && !items.isEmpty }
    var succeededCount: Int {
        items.filter { if case .done = $0.status { return true } else { return false } }.count
    }

    /// Non-empty, whitespace-trimmed lines of a multi-line script — the batch items.
    static func lines(from script: String) -> [String] {
        script
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func start(
        lines: [String],
        audioPlayer: AudioPlayerViewModel,
        ttsEngine: TTSEngineStore,
        outputSubfolder: String,
        caller: String,
        makeRequest: @escaping (_ line: String, _ index: Int, _ total: Int, _ seed: UInt64, _ outputPath: String) -> GenerationRequest,
        makeGeneration: @escaping (_ line: String, _ result: GenerationResult) -> Generation
    ) {
        guard !isRunning, !lines.isEmpty else { return }
        let seed = UInt64.random(in: UInt64.min ... UInt64.max)
        items = lines.enumerated().map { Item(index: $0.offset, text: $0.element) }
        completedCount = 0
        isRunning = true
        audioPlayer.setBatchSuppression(true)
        let total = lines.count

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                audioPlayer.setBatchSuppression(false)
                self.isRunning = false
            }
            for (index, line) in lines.enumerated() {
                if Task.isCancelled { self.markCancelled(from: index); break }
                self.setStatus(index, .generating)
                let outputPath = makeOutputPath(subfolder: outputSubfolder, text: line)
                do {
                    let request = makeRequest(line, index, total, seed, outputPath)
                    let result = try await ttsEngine.generate(request)
                    if Task.isCancelled {
                        try? FileManager.default.removeItem(atPath: result.audioPath)
                        self.markCancelled(from: index)
                        break
                    }
                    GenerationPersistence.persist(
                        makeGeneration(line, result),
                        caller: caller
                    )
                    IOSSavedOutputsDestination.exportIfConfigured(internalAudioPath: result.audioPath)
                    self.setStatus(index, .done(duration: result.durationSeconds))
                    self.completedCount += 1
                } catch is CancellationError {
                    self.markCancelled(from: index)
                    break
                } catch {
                    self.setStatus(index, .failed(error.localizedDescription))
                    self.completedCount += 1
                }
            }
            if self.succeededCount > 0 { IOSHaptics.success() }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func setStatus(_ index: Int, _ status: Item.Status) {
        guard items.indices.contains(index) else { return }
        items[index].status = status
    }

    private func markCancelled(from index: Int) {
        for i in items.indices where i >= index {
            switch items[i].status {
            case .pending, .generating: items[i].status = .cancelled
            default: break
            }
        }
    }
}
