import XCTest
@testable import QwenVoice

final class ModelManagerViewModelTests: XCTestCase {
    @MainActor
    func testInitMarksCompleteModelDirectoryAsDownloaded() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createInstalledModelFixture(for: installedModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        guard case .downloaded = viewModel.statuses[installedModel.id] else {
            return XCTFail("Expected \(installedModel.id) to be marked downloaded at init, got \(String(describing: viewModel.statuses[installedModel.id]))")
        }
        let designModel = try XCTUnwrap(TTSModel.model(for: .design))
        let cloneModel = try XCTUnwrap(TTSModel.model(for: .clone))
        XCTAssertEqual(viewModel.statuses[designModel.id], .notDownloaded(message: nil))
        XCTAssertEqual(viewModel.statuses[cloneModel.id], .notDownloaded(message: nil))
    }

    @MainActor
    func testInitMarksPartialModelDirectoryAsRepairable() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let partialModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createPartialModelFixture(for: partialModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        guard case .repairAvailable(_, let missingRequiredPaths, nil) = viewModel.statuses[partialModel.id] else {
            return XCTFail("Expected \(partialModel.id) to be marked repairable, got \(String(describing: viewModel.statuses[partialModel.id]))")
        }
        XCTAssertFalse(missingRequiredPaths.isEmpty)
        XCTAssertTrue(viewModel.isLikelyInstalled(partialModel))
        XCTAssertEqual(viewModel.primaryActionTitle(for: partialModel), "Repair Model")
    }

    @MainActor
    func testRefreshPromotesCompleteModelDirectoryToDownloaded() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom"))
        try createInstalledModelFixture(for: installedModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        await viewModel.refresh()

        guard case .downloaded = viewModel.statuses[installedModel.id] else {
            return XCTFail("Expected \(installedModel.id) to be marked downloaded after refresh, got \(String(describing: viewModel.statuses[installedModel.id]))")
        }
        let metadataURL = installedModel.installDirectory(in: tempRoot)
            .appendingPathComponent(".qwenvoice-install-metadata.json")
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        XCTAssertEqual(metadata["model_id"] as? String, installedModel.id)
        XCTAssertEqual(metadata["hugging_face_repo"] as? String, installedModel.huggingFaceRepo)
        XCTAssertEqual(metadata["hugging_face_revision"] as? String, installedModel.huggingFaceRevision)
    }

    @MainActor
    func testVariantStatusesAreIndependent() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let speedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        try createInstalledModelFixture(for: speedModel, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)

        guard case .downloaded = viewModel.statuses[speedModel.id] else {
            return XCTFail("Expected \(speedModel.id) to be downloaded.")
        }
        XCTAssertEqual(viewModel.statuses[qualityModel.id], .notDownloaded(message: nil))
    }

    @MainActor
    func testModelSetupSummaryReflectsRecommendedDownloads() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try withClearedVariantPreferences {
            let customSpeed = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
            let designSpeed = try XCTUnwrap(TTSModel.model(id: "pro_design_speed"))
            let cloneSpeed = try XCTUnwrap(TTSModel.model(id: "pro_clone_speed"))

            let empty = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
            XCTAssertEqual(
                empty.modelSetupSummary(),
                ModelManagerViewModel.ModelSetupSummary(
                    installedRecommendedCount: 0,
                    totalRecommendedCount: 3
                )
            )
            XCTAssertEqual(empty.modelSetupSummary().text, "0 of 3 recommended models installed")

            try createInstalledModelFixture(for: customSpeed, in: tempRoot)
            let partial = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
            XCTAssertEqual(partial.modelSetupSummary().installedRecommendedCount, 1)
            XCTAssertEqual(partial.modelSetupSummary().text, "1 of 3 recommended models installed")

            try createInstalledModelFixture(for: designSpeed, in: tempRoot)
            try createInstalledModelFixture(for: cloneSpeed, in: tempRoot)
            let complete = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
            XCTAssertEqual(
                complete.modelSetupSummary(),
                ModelManagerViewModel.ModelSetupSummary(
                    installedRecommendedCount: 3,
                    totalRecommendedCount: 3
                )
            )
            XCTAssertEqual(complete.modelSetupSummary().text, "Recommended models ready")
        }
    }

    @MainActor
    func testRecommendedSetupCandidatesFollowHardwareRecommendation() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try withClearedVariantPreferences {
            let floorViewModel = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
            let floorCandidates = floorViewModel.recommendedSetupCandidates()
            XCTAssertEqual(Set(floorCandidates.map(\.mode)), Set(GenerationMode.allCases))
            XCTAssertTrue(
                floorCandidates.allSatisfy { $0.variantKind == .speed },
                "Floor Macs should set up Speed variants first."
            )

            let midViewModel = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .mid16GBMac)
            let midCandidates = midViewModel.recommendedSetupCandidates()
            XCTAssertEqual(Set(midCandidates.map(\.mode)), Set(GenerationMode.allCases))
            XCTAssertTrue(
                midCandidates.allSatisfy { $0.variantKind == .quality },
                "Higher-memory Macs should set up Quality variants first."
            )
        }
    }

    @MainActor
    func testRecommendedSetupCandidatesSkipReadyRecommendedPackages() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try withClearedVariantPreferences {
            let customSpeed = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
            try createInstalledModelFixture(for: customSpeed, in: tempRoot)

            let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
            let candidates = viewModel.recommendedSetupCandidates()
            XCTAssertFalse(candidates.contains { $0.id == customSpeed.id })
            XCTAssertEqual(Set(candidates.map(\.mode)), Set([.design, .clone]))
        }
    }

    @MainActor
    func testRecommendedSetupCandidatesIgnoreActiveVariantSelection() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        let recommendedSpeed = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        try createInstalledModelFixture(for: qualityModel, in: tempRoot)

        try withClearedVariantPreferences {
            MacModelVariantPreferences.setSelectedVariantID("quality", for: .custom, defaults: .standard)

            let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
            XCTAssertTrue(viewModel.isActive(qualityModel), "Precondition: Quality remains the active generation variant.")
            XCTAssertTrue(
                viewModel.recommendedSetupCandidates().contains { $0.id == recommendedSpeed.id },
                "Settings downloads should still offer the missing hardware-recommended package even when generation currently prefers another installed variant."
            )
            XCTAssertFalse(viewModel.recommendedSetupCandidates().contains { $0.id == qualityModel.id })
        }
    }

    @MainActor
    func testPackagePresentationCoversMissingRepairReadyAndHardwareRisk() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let customSpeed = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        let customQuality = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))

        let missing = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
            .packagePresentation(for: customSpeed)
        XCTAssertEqual(missing.kind, .notInstalled)
        XCTAssertEqual(missing.label, "Not installed")

        try createPartialModelFixture(for: customSpeed, in: tempRoot)
        let repair = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
            .packagePresentation(for: customSpeed)
        XCTAssertEqual(repair.kind, .needsRepair)
        XCTAssertEqual(repair.label, "Needs repair")

        try createInstalledModelFixture(for: customSpeed, in: tempRoot)
        let ready = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
            .packagePresentation(for: customSpeed)
        XCTAssertEqual(ready.kind, .ready)
        XCTAssertEqual(ready.label, "Ready")

        let floorViewModel = ModelManagerViewModel(modelsDirectory: tempRoot, deviceClass: .floor8GBMac)
        XCTAssertTrue(floorViewModel.isHardwareRisky(customQuality))
    }

    @MainActor
    func testUsePersistsActiveVariantSelection() throws {
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        let key = MacModelVariantPreferences.key(for: .custom)
        let oldValue = UserDefaults.standard.string(forKey: key)
        MacModelVariantPreferences.setSelectedVariantID("speed", for: .custom, defaults: .standard)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let viewModel = ModelManagerViewModel()
        viewModel.use(qualityModel)

        XCTAssertEqual(
            MacModelVariantPreferences.selectedVariantID(
                for: .custom,
                defaultVariantID: nil
            ),
            "quality"
        )
        XCTAssertTrue(viewModel.isActive(qualityModel))
    }

    /// Audit Finding B coverage — when the user deletes a variant
    /// that is currently Active AND a sibling variant for the
    /// same mode is still installed, the preference must
    /// reassign to the sibling so the Generate flow stays
    /// enabled without an extra Use click.
    @MainActor
    func testDeleteActiveVariantWithInstalledSiblingReassignsPreference() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let speedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        try createInstalledModelFixture(for: speedModel, in: tempRoot)
        try createInstalledModelFixture(for: qualityModel, in: tempRoot)

        let key = MacModelVariantPreferences.key(for: .custom)
        let oldValue = UserDefaults.standard.string(forKey: key)
        MacModelVariantPreferences.setSelectedVariantID("quality", for: .custom, defaults: .standard)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        XCTAssertTrue(viewModel.isActive(qualityModel), "Pre-condition: Quality is Active.")

        viewModel.delete(qualityModel)

        // Sibling Speed is still installed → preference should
        // reassign to "speed" so Generate stays enabled.
        XCTAssertEqual(
            MacModelVariantPreferences.selectedVariantID(
                for: .custom,
                defaultVariantID: nil
            ),
            "speed",
            "After deleting the Active variant, the preference must reassign to the surviving installed sibling so the Generate button doesn't strand the user."
        )
        XCTAssertTrue(viewModel.isActive(speedModel))
        XCTAssertFalse(viewModel.isActive(qualityModel))
    }

    /// Audit Finding B coverage — when the user deletes their
    /// only-installed variant for a mode, the preference must be
    /// cleared so the hardware-recommended variant becomes
    /// Active again (its row will show as not-yet-installed but
    /// the readiness banner now points the user at a sensible
    /// next step rather than at a deleted folder).
    @MainActor
    func testDeleteActiveVariantWithNoSiblingClearsPreference() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        try createInstalledModelFixture(for: qualityModel, in: tempRoot)

        let key = MacModelVariantPreferences.key(for: .custom)
        let oldValue = UserDefaults.standard.string(forKey: key)
        MacModelVariantPreferences.setSelectedVariantID("quality", for: .custom, defaults: .standard)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        viewModel.delete(qualityModel)

        XCTAssertNil(
            MacModelVariantPreferences.selectedVariantID(
                for: .custom,
                defaultVariantID: nil
            ),
            "After deleting the only installed variant for a mode, the preference must clear so the hardware-recommended variant takes over."
        )
    }

    /// Audit Finding B regression guard — deleting a NON-active
    /// variant (the user's preference points at the OTHER
    /// variant) must not touch the preference.
    @MainActor
    func testDeleteNonActiveVariantLeavesPreferenceUntouched() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let speedModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        let qualityModel = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        try createInstalledModelFixture(for: speedModel, in: tempRoot)
        try createInstalledModelFixture(for: qualityModel, in: tempRoot)

        let key = MacModelVariantPreferences.key(for: .custom)
        let oldValue = UserDefaults.standard.string(forKey: key)
        MacModelVariantPreferences.setSelectedVariantID("quality", for: .custom, defaults: .standard)
        defer {
            if let oldValue {
                UserDefaults.standard.set(oldValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        viewModel.delete(speedModel)  // not the active variant

        XCTAssertEqual(
            MacModelVariantPreferences.selectedVariantID(
                for: .custom,
                defaultVariantID: nil
            ),
            "quality",
            "Deleting a non-active variant must not change the preference."
        )
    }

    private func createInstalledModelFixture(for model: TTSModel, in modelsDirectory: URL) throws {
        let fileManager = FileManager.default
        let modelDirectory = model.installDirectory(in: modelsDirectory)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        for relativePath in model.requiredRelativePaths {
            let fileURL = modelDirectory.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: fileURL)
        }
    }

    /// `sizeText(for:)` is the source of truth for model storage
    /// size presentation. Verifies the three live-state
    /// branches: installed (uses on-disk size), repair-available
    /// (also on-disk size), and not-yet-downloaded (uses the
    /// manifest's `estimatedDownloadBytes` and elides the column
    /// when the field is missing).
    @MainActor
    func testSizeTextReadsInstalledSizeBeforeManifestEstimate() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let installed = try XCTUnwrap(TTSModel.model(id: "pro_custom_speed"))
        try createInstalledModelFixture(for: installed, in: tempRoot)

        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        let installedText = try XCTUnwrap(viewModel.sizeText(for: installed))
        // `createInstalledModelFixture` writes a token file; the
        // exact byte count varies, but `ByteCountFormatter` always
        // emits a unit suffix.
        XCTAssertTrue(
            installedText.hasSuffix("KB") || installedText.hasSuffix("MB") || installedText.hasSuffix("GB") || installedText.hasSuffix("bytes"),
            "Installed size text should carry a unit suffix, got \(installedText)"
        )
    }

    @MainActor
    func testSizeTextReturnsNilWhenNotDownloadedAndManifestHasNoEstimate() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // The shipped manifest now carries an `estimatedDownloadBytes`
        // for every variant, so we can no longer reach the no-estimate
        // branch through `TTSModel.model(id:)`. The branch is still
        // reachable in production whenever a future variant is shipped
        // without a size estimate, so we exercise it by overlaying a
        // synthetic TTSModel that shares the real `pro_custom_quality`
        // id (so the view model's status table resolves to
        // `.notDownloaded`) but sets `estimatedDownloadBytes` to nil.
        let realQuality = try XCTUnwrap(TTSModel.model(id: "pro_custom_quality"))
        let viewModel = ModelManagerViewModel(modelsDirectory: tempRoot)
        XCTAssertEqual(
            viewModel.statuses[realQuality.id],
            .notDownloaded(message: nil),
            "Precondition: the real quality model is not downloaded in the temp root."
        )

        let syntheticNoEstimate = TTSModel(
            id: realQuality.id,
            name: realQuality.name,
            tier: realQuality.tier,
            folder: realQuality.folder,
            mode: realQuality.mode,
            huggingFaceRepo: realQuality.huggingFaceRepo,
            outputSubfolder: realQuality.outputSubfolder,
            requiredRelativePaths: realQuality.requiredRelativePaths,
            baseModelID: realQuality.baseModelID,
            variantID: realQuality.variantID,
            variantKind: realQuality.variantKind,
            estimatedDownloadBytes: nil,
            isHardwareRecommended: realQuality.isHardwareRecommended
        )
        XCTAssertNil(
            viewModel.sizeText(for: syntheticNoEstimate),
            "When the model is not downloaded and the manifest doesn't carry an estimate, sizeText must return nil."
        )

        let syntheticZeroEstimate = TTSModel(
            id: realQuality.id,
            name: realQuality.name,
            tier: realQuality.tier,
            folder: realQuality.folder,
            mode: realQuality.mode,
            huggingFaceRepo: realQuality.huggingFaceRepo,
            outputSubfolder: realQuality.outputSubfolder,
            requiredRelativePaths: realQuality.requiredRelativePaths,
            baseModelID: realQuality.baseModelID,
            variantID: realQuality.variantID,
            variantKind: realQuality.variantKind,
            estimatedDownloadBytes: 0,
            isHardwareRecommended: realQuality.isHardwareRecommended
        )
        XCTAssertNil(
            viewModel.sizeText(for: syntheticZeroEstimate),
            "A zero-byte estimate must be treated the same as a missing estimate."
        )
    }

    private func createPartialModelFixture(for model: TTSModel, in modelsDirectory: URL) throws {
        let fileManager = FileManager.default
        let modelDirectory = model.installDirectory(in: modelsDirectory)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        guard let firstRelativePath = model.requiredRelativePaths.first else {
            XCTFail("Expected requiredRelativePaths for \(model.id)")
            return
        }

        let fileURL = modelDirectory.appendingPathComponent(firstRelativePath)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: fileURL)
    }

    private func withClearedVariantPreferences(_ body: () throws -> Void) rethrows {
        let storedValues = Dictionary(
            uniqueKeysWithValues: GenerationMode.allCases.map {
                ($0, UserDefaults.standard.string(forKey: MacModelVariantPreferences.key(for: $0)))
            }
        )
        defer {
            for mode in GenerationMode.allCases {
                let key = MacModelVariantPreferences.key(for: mode)
                if case .some(.some(let oldValue)) = storedValues[mode] {
                    UserDefaults.standard.set(oldValue, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        for mode in GenerationMode.allCases {
            MacModelVariantPreferences.clearSelectedVariantID(for: mode, defaults: .standard)
        }
        try body()
    }
}

final class HuggingFaceDownloaderPathValidationTests: XCTestCase {
    private let pinnedRevision = "0123456789abcdef0123456789abcdef01234567"

    func testValidatedRelativeRepoPathRejectsTraversal() {
        XCTAssertThrowsError(try HuggingFaceDownloader.validatedRelativeRepoPath("../model.safetensors")) { error in
            guard case HuggingFaceDownloader.DownloadError.invalidRemotePath(let path) = error else {
                return XCTFail("Expected invalidRemotePath, got \(error)")
            }
            XCTAssertEqual(path, "../model.safetensors")
        }
    }

    func testValidatedRelativeRepoPathRejectsHiddenComponents() {
        XCTAssertThrowsError(try HuggingFaceDownloader.validatedRelativeRepoPath("weights/.secret/model.safetensors")) { error in
            guard case HuggingFaceDownloader.DownloadError.invalidRemotePath(let path) = error else {
                return XCTFail("Expected invalidRemotePath, got \(error)")
            }
            XCTAssertEqual(path, "weights/.secret/model.safetensors")
        }
    }

    func testValidatedDestinationURLAllowsNestedSafePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let destination = try HuggingFaceDownloader.validatedDestinationURL(
            for: "speech_tokenizer/model.safetensors",
            in: root
        )

        XCTAssertTrue(destination.path.hasPrefix(root.path + "/"))
        XCTAssertEqual(destination.lastPathComponent, "model.safetensors")
        XCTAssertEqual(destination.deletingLastPathComponent().lastPathComponent, "speech_tokenizer")
    }

    func testRepositoryTreeURLUsesPinnedRevision() {
        let url = HuggingFaceDownloader.repositoryTreeURL(
            apiBaseURL: URL(string: "https://huggingface.co/api/models")!,
            repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            revision: pinnedRevision
        )

        XCTAssertTrue(url.path.hasSuffix("/tree/\(pinnedRevision)"))
        XCTAssertFalse(url.path.contains("/tree/main"))
        XCTAssertEqual(url.query, "recursive=true")
    }

    func testFileResolveURLUsesPinnedRevision() throws {
        let url = try HuggingFaceDownloader.fileResolveURL(
            resolveBaseURL: URL(string: "https://huggingface.co")!,
            repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            revision: pinnedRevision,
            relativePath: "speech_tokenizer/model.safetensors"
        )

        XCTAssertTrue(url.path.contains("/resolve/\(pinnedRevision)/"))
        XCTAssertFalse(url.path.contains("/resolve/main/"))
        XCTAssertTrue(url.path.hasSuffix("/speech_tokenizer/model.safetensors"))
    }
}
