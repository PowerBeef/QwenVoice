import Foundation

@MainActor
extension PythonBridge {
    func initialize(appSupportDir: String) async throws {
        if isStubBackendMode {
            try await stubTransport.initialize()
            isReady = true
            streamCoordinator.removeAll()
            modelLoadCoordinator.reset()
            activeAppSupportDir = appSupportDir
            lastError = nil
            syncSidebarStatusFromSystemState()
            return
        }

        _ = try await callDict("init", params: [
            "app_support_dir": .string(appSupportDir)
        ])
        streamCoordinator.removeAll()
        modelLoadCoordinator.reset()
        activeAppSupportDir = appSupportDir
    }

    func ping() async throws -> Bool {
        if isStubBackendMode {
            return true
        }
        let result = try await callDict("ping")
        return result["status"]?.stringValue == "ok"
    }

    func loadModel(id: String) async throws -> [String: RPCValue] {
        try await loadModel(id: id, reportsErrors: true, resetLastError: true)
    }

    func loadModel(
        id: String,
        reportsErrors: Bool,
        resetLastError: Bool
    ) async throws -> [String: RPCValue] {
        try await modelLoadCoordinator.loadModel(id: id) {
            if self.isStubBackendMode {
                return try await self.stubTransport.loadModel(id: id)
            }

            return try await self.callDict(
                "load_model",
                params: [
                    "model_id": .string(id)
                ],
                reportsErrors: reportsErrors,
                resetLastError: resetLastError
            )
        }
    }

    func ensureModelLoadedIfNeeded(id: String) async {
        guard isReady else { return }
        guard processManager.isRunning || isStubBackendMode else { return }
        guard !activityCoordinator.hasActiveGenerationSession else { return }
        guard !modelLoadCoordinator.canSkipLoadModel(requestedID: id) else { return }

        if isProcessing, modelLoadCoordinator.currentLoadedModelID != id {
            return
        }

        do {
            _ = try await loadModel(id: id, reportsErrors: false, resetLastError: false)
        } catch {
            #if DEBUG
            print("[Performance][PythonBridge] ensure_model_loaded_failed id=\(id) error=\(error.localizedDescription)")
            #endif
        }
    }

    func unloadModel() async throws {
        if isStubBackendMode {
            modelLoadCoordinator.markUnloaded()
            return
        }
        _ = try await callDict("unload_model")
        modelLoadCoordinator.markUnloaded()
    }

    func prewarmModelIfNeeded(
        modelID: String,
        mode: GenerationMode,
        voice: String? = nil,
        instruct: String? = nil,
        refAudio: String? = nil,
        refText: String? = nil
    ) async {
        guard isReady else { return }
        guard processManager.isRunning || isStubBackendMode else { return }
        guard !isProcessing, !activityCoordinator.hasActiveGenerationSession else { return }
        guard Self.supportsIdlePrewarm(mode: mode) else { return }
        if mode == .clone && (refAudio?.isEmpty ?? true) {
            return
        }

        let prewarmKey = Self.prewarmIdentityKey(
            modelID: modelID,
            mode: mode,
            voice: voice,
            instruct: instruct,
            refAudio: refAudio,
            refText: refText
        )

        let didPrewarm = await modelLoadCoordinator.prewarmIfNeeded(key: prewarmKey) {
            if self.isStubBackendMode {
                self.modelLoadCoordinator.markLoadedModel(id: modelID)
                return
            }

            var params: [String: RPCValue] = [
                "model_id": .string(modelID),
                "mode": .string(mode.rawValue),
            ]
            switch mode {
            case .custom:
                if let voice, !voice.isEmpty {
                    params["voice"] = .string(voice)
                }
                if let instruct, !instruct.isEmpty, Self.hasMeaningfulDeliveryInstruction(instruct) {
                    params["instruct"] = .string(instruct)
                }
            case .design:
                break
            case .clone:
                if let refAudio, !refAudio.isEmpty {
                    params["ref_audio"] = .string(refAudio)
                }
                if let refText, !refText.isEmpty {
                    params["ref_text"] = .string(refText)
                }
            }

            _ = try await self.callDict(
                "prewarm_model",
                params: params,
                reportsErrors: false,
                resetLastError: false
            )
            self.modelLoadCoordinator.markLoadedModel(id: modelID)
        }

        if didPrewarm {
            modelLoadCoordinator.markLoadedModel(id: modelID)
        }
    }

    func cancelCloneReferencePrimingIfNeeded() async {
        guard cloneReferencePrimingPhase == .preparing else { return }
        guard let pythonPath = processManager.activePythonPath,
              let appSupportDir = activeAppSupportDir else {
            resetCloneReferencePrimingState()
            return
        }

        do {
            try await cancelActiveGenerationAndRestart(
                pythonPath: pythonPath,
                appSupportDir: appSupportDir
            )
        } catch {
            setCloneReferencePrimingState(
                .failed,
                key: cloneReferencePrimingKey,
                error: error.localizedDescription
            )
        }
    }

    func beginCloneModelLoadIfPossible(modelID: String) {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.ensureModelLoadedIfNeeded(id: trimmedModelID)
        }
    }

    func ensureCloneReferencePrimed(
        modelID: String,
        refAudio: String,
        refText: String?
    ) async throws {
        let trimmedRefAudio = refAudio.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRefAudio.isEmpty else { return }
        guard isReady else { return }
        guard processManager.isRunning || isStubBackendMode else { return }
        guard !activityCoordinator.hasActiveGenerationSession else { return }

        let key = Self.cloneReferenceIdentityKey(
            modelID: modelID,
            refAudio: trimmedRefAudio,
            refText: refText
        )

        if clonePreparationCoordinator.hasInFlightTask(for: key) {
            try await clonePreparationCoordinator.ensurePrimed(key: key) { [:] }
            syncCloneReferencePrimingPublishedState()
            return
        }

        if clonePreparationCoordinator.hasDifferentInFlightKey(key) {
            await cancelCloneReferencePrimingIfNeeded()
        }

        if isStubBackendMode {
            modelLoadCoordinator.markLoadedModel(id: modelID)
            setCloneReferencePrimingState(.primed, key: key)
            return
        }

        let trimmedRefText = refText?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await clonePreparationCoordinator.ensurePrimed(key: key) {
                var params: [String: RPCValue] = [
                    "model_id": .string(modelID),
                    "ref_audio": .string(trimmedRefAudio),
                    "streaming_interval": .double(Self.appStreamingInterval),
                ]
                if let trimmedRefText, !trimmedRefText.isEmpty {
                    params["ref_text"] = .string(trimmedRefText)
                }
                return try await self.callDict(
                    "prime_clone_reference",
                    params: params,
                    reportsErrors: false,
                    resetLastError: false
                )
            }
            modelLoadCoordinator.markLoadedModel(id: modelID)
        } catch {
            syncCloneReferencePrimingPublishedState()
            throw error
        }
        syncCloneReferencePrimingPublishedState()
    }

    func cancelActiveGenerationAndRestart(pythonPath: String, appSupportDir: String) async throws {
        if isStubBackendMode {
            transport.cancelAllPending(error: PythonBridgeError.cancelled)
            isReady = false
            isProcessing = false
            streamCoordinator.removeAll()
            modelLoadCoordinator.reset()
            lastError = nil
            resetCloneReferencePrimingState()
            activityCoordinator.clearGenerationActivity()
            syncActivityPublishedState()
            try await initialize(appSupportDir: appSupportDir)
            clearGenerationActivity()
            return
        }

        transport.cancelAllPending(error: PythonBridgeError.cancelled)
        isReady = false
        isProcessing = false
        streamCoordinator.removeAll()
        modelLoadCoordinator.reset()
        lastError = nil
        resetCloneReferencePrimingState()
        activityCoordinator.clearGenerationActivity()
        syncActivityPublishedState()
        transport.reset()

        guard let serverPath = Self.findServerScript() else {
            throw PythonBridgeError.restartFailed("Cannot find server.py")
        }

        do {
            try await processManager.restart(
                pythonPath: pythonPath,
                serverPath: serverPath,
                ffmpegPath: Self.findFFmpeg(),
                onStdoutChunk: { [weak self] text in
                    self?.transport.processOutputChunk(text)
                },
                onStderrText: { text in
                    #if DEBUG
                    print("[Python stderr] \(text)", terminator: "")
                    #endif
                },
                onTerminate: { [weak self] shouldReportCrash, lastStderrLine in
                    guard let self else { return }
                    self.isReady = false
                    self.isProcessing = false
                    self.streamCoordinator.removeAll()
                    self.modelLoadCoordinator.reset()
                    self.resetCloneReferencePrimingState()
                    self.activityCoordinator.clearGenerationActivity()
                    self.syncActivityPublishedState()
                    if shouldReportCrash {
                        self.lastError = lastStderrLine ?? PythonBridgeError.processTerminated.localizedDescription
                    }
                    self.transport.cancelAllPending(error: PythonBridgeError.processTerminated)
                    self.transport.reset()
                }
            )
        } catch {
            throw PythonBridgeError.restartFailed(lastError ?? "Failed to restart Python backend")
        }

        do {
            try await initialize(appSupportDir: appSupportDir)
            clearGenerationActivity()
        } catch {
            stop()
            throw PythonBridgeError.restartFailed(error.localizedDescription)
        }
    }

    func syncSidebarStatusFromSystemState() {
        activityCoordinator.syncSidebarStatusFromSystemState(isReady: isReady, lastError: lastError)
        syncActivityPublishedState()
    }

    func syncActivityPublishedState() {
        progressPercent = activityCoordinator.progressPercent
        progressMessage = activityCoordinator.progressMessage
        sidebarStatus = activityCoordinator.sidebarStatus
    }

    func handleNotification(_ response: RPCResponse) {
        switch response.method {
        case "ready":
            isReady = true
        case "progress":
            guard let params = response.params else { return }
            activityCoordinator.recordProgressNotification(
                requestID: params["request_id"]?.intValue,
                percent: params["percent"]?.intValue ?? 0,
                message: params["message"]?.stringValue ?? ""
            )
            syncActivityPublishedState()
        case "generation_chunk":
            guard let params = response.params else { return }
            streamCoordinator.handleGenerationChunkNotification(params)
        default:
            break
        }
    }
}
