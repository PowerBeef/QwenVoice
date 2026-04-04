import Foundation

@MainActor
final class PythonBridgeActivityCoordinator {
    enum CompletionOutcome {
        case noSession
        case advancedBatch
        case finished
    }

    private struct GenerationSession {
        var mode: GenerationMode
        var batchIndex: Int?
        var batchTotal: Int?
        var currentPhase: GenerationPhase
        var currentRequestID: Int?
        var activityPresentation: ActivityStatus.Presentation
    }

    private enum GenerationPhase {
        case loadingModel
        case preparing
        case generating
        case saving
    }

    private var activeProgressRequestID: Int?
    private var activeProgressMethod: String?
    private var activeCloneBatchProgressHandler: ((Double?, String) -> Void)?
    private var activeGenerationSession: GenerationSession?
    private var sidebarStatusResetTask: Task<Void, Never>?

    private(set) var progressPercent: Int = 0
    private(set) var progressMessage: String = ""
    private(set) var sidebarStatus: SidebarStatus = .starting

    var hasActiveGenerationSession: Bool {
        activeGenerationSession != nil
    }

    func setCloneBatchProgressHandler(_ progressHandler: ((Double?, String) -> Void)?) {
        activeCloneBatchProgressHandler = progressHandler
    }

    func beginRequestTracking(id: Int, method: String) {
        progressPercent = 0
        progressMessage = ""

        guard method == "load_model"
                || method == "generate"
                || method == "generate_clone_batch" else {
            return
        }

        activeProgressRequestID = id
        activeProgressMethod = method
        setCurrentRequestID(id)
    }

    func finishRequestTracking(id: Int) {
        progressPercent = 0
        progressMessage = ""

        if activeProgressRequestID == id {
            clearActiveProgressTracking()
        }
        if activeGenerationSession?.currentRequestID == id {
            setCurrentRequestID(nil)
        }
    }

    func beginGenerationSession(
        mode: GenerationMode,
        batchIndex: Int?,
        batchTotal: Int?,
        activityPresentation: ActivityStatus.Presentation
    ) {
        cancelSidebarStatusReset()
        activeGenerationSession = GenerationSession(
            mode: mode,
            batchIndex: batchIndex,
            batchTotal: batchTotal,
            currentPhase: .loadingModel,
            currentRequestID: nil,
            activityPresentation: activityPresentation
        )
        updateCurrentSession(
            phase: .loadingModel,
            message: "Preparing model...",
            requestFraction: 0.0
        )
    }

    func markPreparingRequest() {
        updateCurrentSession(
            phase: .preparing,
            message: "Preparing request...",
            requestFraction: 0.15
        )
    }

    func completeGenerationSession() -> CompletionOutcome {
        guard var session = activeGenerationSession else {
            return .noSession
        }

        clearActiveProgressTracking()

        if let batchIndex = session.batchIndex,
           let batchTotal = session.batchTotal,
           batchIndex < batchTotal {
            session.batchIndex = batchIndex + 1
            session.currentPhase = .loadingModel
            session.currentRequestID = nil
            activeGenerationSession = session
            updateCurrentSession(
                phase: .loadingModel,
                message: "Preparing model...",
                requestFraction: 0.0
            )
            return .advancedBatch
        }

        activeGenerationSession = nil
        return .finished
    }

    func failGenerationSession() {
        cancelSidebarStatusReset()
        activeGenerationSession = nil
        clearActiveProgressTracking()
        activeCloneBatchProgressHandler = nil
        progressPercent = 0
        progressMessage = ""
    }

    func clearGenerationActivity() {
        cancelSidebarStatusReset()
        activeGenerationSession = nil
        clearActiveProgressTracking()
        activeCloneBatchProgressHandler = nil
        progressPercent = 0
        progressMessage = ""
    }

    func syncSidebarStatusFromSystemState(isReady: Bool, lastError: String?) {
        cancelSidebarStatusReset()
        if let error = lastError {
            sidebarStatus = isReady ? .error(error) : .crashed(error)
            return
        }
        guard activeGenerationSession == nil else { return }
        sidebarStatus = isReady ? .idle : .starting
    }

    func recordProgressNotification(
        requestID: Int?,
        percent: Int,
        message: String
    ) {
        if let expectedRequestID = activeProgressRequestID,
           let requestID,
           requestID != expectedRequestID {
            return
        }

        progressPercent = percent
        progressMessage = message

        guard activeGenerationSession != nil,
              let activeProgressMethod else {
            return
        }

        updateSidebarFromProgress(
            method: activeProgressMethod,
            percent: percent,
            message: message
        )

        if activeProgressMethod == "generate_clone_batch" {
            activeCloneBatchProgressHandler?(
                Double(progressPercent) / 100.0,
                progressMessage
            )
        }
    }

    func scheduleSidebarStatusReset(onExpire: @escaping @MainActor () -> Void) {
        cancelSidebarStatusReset()
        sidebarStatusResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.finishSidebarStatusResetIfCurrent(onExpire: onExpire)
        }
    }

    private func updateSidebarFromProgress(method: String, percent: Int, message: String) {
        guard let session = activeGenerationSession else { return }
        let phase = phaseForProgress(method: method, message: message, mode: session.mode)
        let requestFraction = mappedRequestFraction(method: method, percent: percent)
        updateCurrentSession(phase: phase, message: message, requestFraction: requestFraction)
    }

    private func updateCurrentSession(phase: GenerationPhase, message: String, requestFraction: Double?) {
        guard var session = activeGenerationSession else { return }
        cancelSidebarStatusReset()
        session.currentPhase = phase
        activeGenerationSession = session
        let overallFraction = overallFraction(for: session, requestFraction: requestFraction)
        let label = sidebarLabel(for: session, message: message)
        sidebarStatus = .running(
            ActivityStatus(
                label: label,
                fraction: overallFraction,
                presentation: session.activityPresentation
            )
        )
    }

    private func phaseForProgress(method: String, message: String, mode: GenerationMode) -> GenerationPhase {
        switch method {
        case "load_model":
            return .loadingModel
        case "generate", "generate_clone_batch":
            let lowercasedMessage = message.lowercased()
            if lowercasedMessage.contains("saving") || lowercasedMessage.contains("done") {
                return .saving
            }
            if lowercasedMessage.contains("generating") || lowercasedMessage.contains("streaming") {
                return .generating
            }
            if mode == .clone && (lowercasedMessage.contains("normalizing") || lowercasedMessage.contains("voice context")) {
                return .preparing
            }
            return .preparing
        default:
            return .preparing
        }
    }

    private func mappedRequestFraction(method: String, percent: Int) -> Double? {
        let clampedPercent = min(max(percent, 0), 100)
        let normalized = Double(clampedPercent) / 100.0

        switch method {
        case "load_model":
            return normalized * 0.15
        case "generate", "generate_clone_batch":
            return 0.15 + (normalized * 0.85)
        default:
            return normalized
        }
    }

    private func overallFraction(for session: GenerationSession, requestFraction: Double?) -> Double? {
        guard let requestFraction else { return nil }
        guard let batchIndex = session.batchIndex,
              let batchTotal = session.batchTotal,
              batchTotal > 0 else {
            return min(max(requestFraction, 0.0), 1.0)
        }

        let completedItems = max(batchIndex - 1, 0)
        let overall = (Double(completedItems) + requestFraction) / Double(batchTotal)
        return min(max(overall, 0.0), 1.0)
    }

    private func sidebarLabel(for session: GenerationSession, message: String) -> String {
        guard let batchIndex = session.batchIndex,
              let batchTotal = session.batchTotal else {
            return message
        }
        return "Generating \(batchIndex)/\(batchTotal): \(message)"
    }

    private func cancelSidebarStatusReset() {
        sidebarStatusResetTask?.cancel()
        sidebarStatusResetTask = nil
    }

    private func clearActiveProgressTracking() {
        activeProgressRequestID = nil
        activeProgressMethod = nil
    }

    private func setCurrentRequestID(_ requestID: Int?) {
        guard var session = activeGenerationSession else { return }
        session.currentRequestID = requestID
        activeGenerationSession = session
    }

    private func finishSidebarStatusResetIfCurrent(onExpire: @escaping @MainActor () -> Void) {
        sidebarStatusResetTask = nil
        onExpire()
    }
}
