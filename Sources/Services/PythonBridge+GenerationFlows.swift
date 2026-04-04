import Foundation

@MainActor
extension PythonBridge {
    func generateCustom(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        outputPath: String,
        stream: Bool = false,
        streamingContext: StreamingRequestContext? = nil
    ) async throws -> GenerationResult {
        if isStubBackendMode {
            return try await stubTransport.generate(
                mode: .custom,
                text: text,
                outputPath: outputPath,
                stream: stream,
                streamingContext: streamingContext
            )
        }

        var params: [String: RPCValue] = [
            "model_id": .string(modelID),
            "mode": .string(GenerationMode.custom.rawValue),
            "text": .string(text),
            "voice": .string(voice),
            "instruct": .string(emotion),
            "output_path": .string(outputPath),
        ]
        if stream {
            params["stream"] = .bool(true)
            params["streaming_interval"] = .double(Self.appStreamingInterval)
        }
        let result = try await callDict("generate", params: params, streamingContext: streamingContext)
        return GenerationResult(from: result)
    }

    func generateDesign(
        modelID: String,
        text: String,
        voiceDescription: String,
        emotion: String,
        outputPath: String,
        stream: Bool = false,
        streamingContext: StreamingRequestContext? = nil
    ) async throws -> GenerationResult {
        if isStubBackendMode {
            return try await stubTransport.generate(
                mode: .design,
                text: text,
                outputPath: outputPath,
                stream: stream,
                streamingContext: streamingContext
            )
        }

        var params: [String: RPCValue] = [
            "model_id": .string(modelID),
            "mode": .string(GenerationMode.design.rawValue),
            "text": .string(text),
            "instruct": .string(Self.designInstruction(voiceDescription: voiceDescription, emotion: emotion)),
            "output_path": .string(outputPath),
        ]
        if stream {
            params["stream"] = .bool(true)
            params["streaming_interval"] = .double(Self.appStreamingInterval)
        }
        let result = try await callDict("generate", params: params, streamingContext: streamingContext)
        return GenerationResult(from: result)
    }

    func generateClone(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        outputPath: String,
        stream: Bool = false,
        streamingContext: StreamingRequestContext? = nil
    ) async throws -> GenerationResult {
        if isStubBackendMode {
            return try await stubTransport.generate(
                mode: .clone,
                text: text,
                outputPath: outputPath,
                stream: stream,
                streamingContext: streamingContext
            )
        }

        var params: [String: RPCValue] = [
            "model_id": .string(modelID),
            "mode": .string(GenerationMode.clone.rawValue),
            "text": .string(text),
            "ref_audio": .string(refAudio),
            "output_path": .string(outputPath),
        ]
        if let refText, !refText.isEmpty {
            params["ref_text"] = .string(refText)
        }
        if stream {
            params["stream"] = .bool(true)
            params["streaming_interval"] = .double(Self.appStreamingInterval)
        }
        let result = try await callDict("generate", params: params, streamingContext: streamingContext)
        return GenerationResult(from: result)
    }

    func generateCloneBatch(
        modelID: String,
        texts: [String],
        refAudio: String,
        refText: String?,
        outputPaths: [String]
    ) async throws -> [GenerationResult] {
        if isStubBackendMode {
            return try await stubTransport.generateCloneBatch(
                texts: texts,
                outputPaths: outputPaths
            )
        }

        var params: [String: RPCValue] = [
            "model_id": .string(modelID),
            "texts": .array(texts.map { .string($0) }),
            "ref_audio": .string(refAudio),
            "output_paths": .array(outputPaths.map { .string($0) }),
        ]
        if let refText, !refText.isEmpty {
            params["ref_text"] = .string(refText)
        }

        let items = try await callArray("generate_clone_batch", params: params)
        return try generationResults(from: items)
    }

    func generateCustomFlow(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        outputPath: String,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .custom,
            modelID: modelID,
            batchIndex: batchIndex,
            batchTotal: batchTotal
        ) {
            try await self.generateCustom(
                modelID: modelID,
                text: text,
                voice: voice,
                emotion: emotion,
                outputPath: outputPath,
                stream: false
            )
        }
    }

    func generateCustomStreamingFlow(
        modelID: String,
        text: String,
        voice: String,
        emotion: String,
        outputPath: String
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .custom,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil,
            activityPresentation: .inlinePlayer
        ) {
            try await self.generateCustom(
                modelID: modelID,
                text: text,
                voice: voice,
                emotion: emotion,
                outputPath: outputPath,
                stream: true,
                streamingContext: StreamingRequestContext(
                    mode: .custom,
                    title: Self.streamingTitle(for: text)
                )
            )
        }
    }

    func generateDesignFlow(
        modelID: String,
        text: String,
        voiceDescription: String,
        emotion: String,
        outputPath: String,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .design,
            modelID: modelID,
            batchIndex: batchIndex,
            batchTotal: batchTotal
        ) {
            try await self.generateDesign(
                modelID: modelID,
                text: text,
                voiceDescription: voiceDescription,
                emotion: emotion,
                outputPath: outputPath,
                stream: false
            )
        }
    }

    func generateDesignStreamingFlow(
        modelID: String,
        text: String,
        voiceDescription: String,
        emotion: String,
        outputPath: String
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .design,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil,
            activityPresentation: .inlinePlayer
        ) {
            try await self.generateDesign(
                modelID: modelID,
                text: text,
                voiceDescription: voiceDescription,
                emotion: emotion,
                outputPath: outputPath,
                stream: true,
                streamingContext: StreamingRequestContext(
                    mode: .design,
                    title: Self.streamingTitle(for: text)
                )
            )
        }
    }

    func generateCloneFlow(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        outputPath: String,
        batchIndex: Int? = nil,
        batchTotal: Int? = nil
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .clone,
            modelID: modelID,
            batchIndex: batchIndex,
            batchTotal: batchTotal
        ) {
            try await self.generateClone(
                modelID: modelID,
                text: text,
                refAudio: refAudio,
                refText: refText,
                outputPath: outputPath,
                stream: false
            )
        }
    }

    func generateCloneBatchFlow(
        modelID: String,
        texts: [String],
        refAudio: String,
        refText: String?,
        outputPaths: [String],
        progressHandler: ((Double?, String) -> Void)?
    ) async throws -> [GenerationResult] {
        activityCoordinator.setCloneBatchProgressHandler(progressHandler)
        defer { activityCoordinator.setCloneBatchProgressHandler(nil) }

        return try await performGenerationFlow(
            mode: .clone,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil
        ) {
            try await self.generateCloneBatch(
                modelID: modelID,
                texts: texts,
                refAudio: refAudio,
                refText: refText,
                outputPaths: outputPaths
            )
        }
    }

    func generateCloneStreamingFlow(
        modelID: String,
        text: String,
        refAudio: String,
        refText: String?,
        outputPath: String
    ) async throws -> GenerationResult {
        try await performGenerationFlow(
            mode: .clone,
            modelID: modelID,
            batchIndex: nil,
            batchTotal: nil,
            activityPresentation: .inlinePlayer
        ) {
            try await self.generateClone(
                modelID: modelID,
                text: text,
                refAudio: refAudio,
                refText: refText,
                outputPath: outputPath,
                stream: true,
                streamingContext: StreamingRequestContext(
                    mode: .clone,
                    title: Self.streamingTitle(for: text)
                )
            )
        }
    }

    func clearGenerationActivity() {
        activityCoordinator.clearGenerationActivity()
        syncSidebarStatusFromSystemState()
    }

    func performGenerationFlow<Output>(
        mode: GenerationMode,
        modelID: String,
        batchIndex: Int?,
        batchTotal: Int?,
        activityPresentation: ActivityStatus.Presentation = .standaloneCard,
        generate: @MainActor () async throws -> Output
    ) async throws -> Output {
        activityCoordinator.beginGenerationSession(
            mode: mode,
            batchIndex: batchIndex,
            batchTotal: batchTotal,
            activityPresentation: activityPresentation
        )
        lastError = nil
        syncActivityPublishedState()

        do {
            let loadStart = DispatchTime.now().uptimeNanoseconds
            let loadResult: [String: RPCValue]
            do {
                let loadSignpost = AppPerformanceSignposts.begin("Model Load")
                defer { AppPerformanceSignposts.end(loadSignpost) }
                loadResult = try await loadModel(id: modelID)
            }
            let loadElapsedMs = Int((DispatchTime.now().uptimeNanoseconds - loadStart) / 1_000_000)
            let loadWasCached = loadResult["cached"]?.boolValue == true
            #if DEBUG
            print("[Performance][PythonBridge] mode=\(mode.rawValue) load_model_client_wall_ms=\(loadElapsedMs) cached=\(loadWasCached)")
            #endif
            if loadWasCached {
                activityCoordinator.markPreparingRequest()
                syncActivityPublishedState()
            }

            let generateStart = DispatchTime.now().uptimeNanoseconds
            let result = try await generate()
            let generateElapsedMs = Int((DispatchTime.now().uptimeNanoseconds - generateStart) / 1_000_000)
            #if DEBUG
            print("[Performance][PythonBridge] mode=\(mode.rawValue) generate_client_wall_ms=\(generateElapsedMs)")
            #endif

            switch activityCoordinator.completeGenerationSession() {
            case .noSession:
                syncSidebarStatusFromSystemState()
            case .advancedBatch:
                syncActivityPublishedState()
            case .finished:
                syncActivityPublishedState()
                activityCoordinator.scheduleSidebarStatusReset { [weak self] in
                    self?.syncSidebarStatusFromSystemState()
                }
            }

            return result
        } catch {
            activityCoordinator.failGenerationSession()
            if lastError == nil {
                lastError = error.localizedDescription
            } else {
                syncSidebarStatusFromSystemState()
            }
            throw error
        }
    }
}
