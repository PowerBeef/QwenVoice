import SwiftUI
import QwenVoiceCore
import AppKit

/// Unified Settings surface, modeled on macOS System Settings.
///
/// Replaces the prior split between an in-app Models tab and a
/// Cmd+, Preferences window. Six grouped sections, top to bottom:
/// one per generation mode (Custom Voice, Voice Design, Voice
/// Cloning), then Playback, Storage, About. Form rows follow the
/// System Settings idiom: leading status indicator, two-line
/// label/sublabel, trailing single primary control.
///
/// Mode color is contained to a small 8x8 dot in the section
/// header, never on the row itself. Active state is signalled by
/// a system-green check in the row's leading slot, but only when
/// the variant is BOTH selected and on disk (`isLiveActive`).
/// Hardware risk surfaces as an inline orange triangle next to
/// the variant name with a hover explanation.
struct SettingsView: View {
    @EnvironmentObject private var viewModel: ModelManagerViewModel
    @Binding var highlightedModelID: String?

    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("outputDirectory") private var outputDirectory = ""
    @AppStorage(AudioService.smoothPlaybackKey) private var smoothPlayback = false

    @State private var flashedModelID: String?
    @State private var modelToDelete: TTSModel?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ForEach(GenerationMode.allCases, id: \.self) { mode in
                    Section {
                        let pair = viewModel.pairedVariants(for: mode)
                        if let speed = pair.speed {
                            VariantRow(
                                model: speed,
                                viewModel: viewModel,
                                isFlashed: flashedModelID == speed.id,
                                onDelete: { request(delete: speed) }
                            )
                            .id(speed.id)
                        }
                        if let quality = pair.quality {
                            VariantRow(
                                model: quality,
                                viewModel: viewModel,
                                isFlashed: flashedModelID == quality.id,
                                onDelete: { request(delete: quality) }
                            )
                            .id(quality.id)
                        }
                    } header: {
                        ModeSectionHeader(mode: mode)
                    }
                }

                Section("Playback") {
                    Toggle("Auto-play generated audio", isOn: $autoPlay)
                        .tint(AppTheme.preferences)
                        .accessibilityIdentifier("preferences_autoPlayToggle")
                    Text("Play the latest result automatically after generation finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Smooth playback", isOn: $smoothPlayback)
                        .tint(AppTheme.preferences)
                        .accessibilityIdentifier("preferences_smoothPlaybackToggle")
                    Text("Wait for enough audio to play through long scripts without buffering pauses. Adds a few seconds before audio starts; eliminates mid-playback interruptions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Storage") {
                    LabeledContent("Output directory") {
                        HStack(spacing: 6) {
                            Text(outputDirectorySummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("preferences_outputDirectory")
                            Button("Choose…") {
                                browseForOutputDirectory()
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("preferences_browseButton")
                            if !outputDirectory.isEmpty {
                                Button("Reset") {
                                    outputDirectory = ""
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("preferences_outputResetButton")
                            }
                        }
                    }

                    LabeledContent("Application data") {
                        Button("Open in Finder") {
                            NSWorkspace.shared.open(QwenVoiceApp.appSupportDir)
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("preferences_openFinderButton")
                    }
                }

                Section("About") {
                    LabeledContent("Vocello") {
                        Text(appVersion)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("Vocello runs natively. Generation and voice management stay in the Swift runtime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("preferences_nativeMaintenanceNote")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Settings")
            .accessibilityIdentifier("screen_settings")
            .task {
                await viewModel.refresh()
                focusHighlightedModel(using: proxy)
            }
            .onChange(of: highlightedModelID) { _, _ in
                focusHighlightedModel(using: proxy)
            }
        }
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { modelToDelete = nil }
            Button("Delete", role: .destructive) {
                if let model = modelToDelete { viewModel.delete(model) }
                modelToDelete = nil
            }
        } message: {
            if let model = modelToDelete {
                let status = viewModel.statuses[model.id]
                let sizeText: String = {
                    if case .downloaded(let sizeBytes) = status {
                        return " (\(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)))"
                    }
                    return ""
                }()
                Text("This will delete \"\(model.name)\"\(sizeText) from disk.")
            }
        }
    }

    private func request(delete model: TTSModel) {
        modelToDelete = model
        showDeleteConfirmation = true
    }

    private var outputDirectorySummary: String {
        if outputDirectory.isEmpty {
            return "Default location"
        }
        return outputDirectory
    }

    private func browseForOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary ?? [:]
        let version = dict["CFBundleShortVersionString"] as? String ?? "?"
        let build = dict["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func focusHighlightedModel(using proxy: ScrollViewProxy) {
        guard let highlightedModelID else { return }
        let modelID = highlightedModelID
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            proxy.scrollTo(modelID, anchor: .center)
        }
        flashedModelID = modelID
        self.highlightedModelID = nil

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if flashedModelID == modelID { flashedModelID = nil }
            }
        }
    }
}

// MARK: - Mode section header

private struct ModeSectionHeader: View {
    let mode: GenerationMode

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(AppTheme.modeColor(for: mode))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(mode.displayName)
        }
    }
}

// MARK: - Variant row

/// Two-line `LabeledContent` row, native System Settings shape.
/// Leading green check appears only when the variant is the
/// active selection AND on disk. Trailing carries one primary
/// control whose role flips with the variant's status.
private struct VariantRow: View {
    let model: TTSModel
    @ObservedObject var viewModel: ModelManagerViewModel
    let isFlashed: Bool
    let onDelete: () -> Void

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .checking
    }

    private var isDownloaded: Bool {
        if case .downloaded = status { return true }
        return false
    }

    private var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    private var isLiveActive: Bool {
        viewModel.isActive(model) && isDownloaded
    }

    private var isHardwareRisky: Bool { viewModel.isHardwareRisky(model) }
    private var isHardwareRecommended: Bool { model.isHardwareRecommended }

    var body: some View {
        LabeledContent {
            actionView
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if isLiveActive {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.bold))
                            .foregroundStyle(Color.green)
                            .accessibilityHidden(true)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14, height: 18)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(model.variantKind?.displayName ?? model.name)
                            .font(.body)
                        if isHardwareRisky {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("This variant may exceed memory available on your Mac. Generation could fail or be very slow. The 4-bit variant is the safe choice for your hardware.")
                                .accessibilityLabel("Hardware warning")
                        }
                    }
                    Text(secondaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listRowBackground(isFlashed ? Color.accentColor.opacity(0.10) : nil)
        .accessibilityIdentifier("settings_variant_\(model.id)")
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            if isDownloaded {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let kind = model.variantKind {
            parts.append(kind.bitDepthLabel)
        }
        if let size = viewModel.sizeText(for: model) {
            parts.append(size)
        }
        switch status {
        case .checking:
            parts.append("Checking local files")
        case .downloading(let progress):
            if let total = progress.totalBytes, total > 0 {
                let downloaded = ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)
                let totalString = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                parts.append("Downloading. \(downloaded) of \(totalString)")
            } else {
                parts.append("Downloading")
            }
        case .repairAvailable(_, let missingPaths, _):
            if missingPaths.isEmpty {
                parts.append("Local files incomplete. Repair to keep using this variant")
            } else {
                let count = missingPaths.count
                parts.append("Needs repair. \(count) required file\(count == 1 ? "" : "s") missing")
            }
        case .notDownloaded:
            if isHardwareRecommended {
                parts.append("Recommended for your Mac")
            } else if isHardwareRisky {
                parts.append("Heavy for your Mac")
            } else {
                parts.append("Available")
            }
        case .downloaded:
            if isLiveActive {
                parts.append("Active")
            } else {
                parts.append("Installed")
            }
        }
        return parts.joined(separator: ". ") + "."
    }

    private var accessibilityLabel: String {
        let kind = model.variantKind?.displayName ?? model.name
        var parts: [String] = [model.mode.displayName, kind, secondaryLine]
        if isLiveActive { parts.append("Active") }
        if isHardwareRecommended { parts.append("Recommended for your Mac") }
        if isHardwareRisky { parts.append("Hardware warning") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var actionView: some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("settings_checking_\(model.id)")
        case .notDownloaded:
            Button("Get") {
                Task { await viewModel.download(model) }
            }
            .controlSize(.small)
            .accessibilityIdentifier("settings_get_\(model.id)")
        case .downloading(let progress):
            DownloadingControl(progress: progress) {
                viewModel.cancelDownload(model)
            }
        case .repairAvailable:
            Button("Repair") {
                Task { await viewModel.download(model) }
            }
            .controlSize(.small)
            .tint(.orange)
            .accessibilityIdentifier("settings_repair_\(model.id)")
        case .downloaded:
            if isLiveActive {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Delete \(model.variantKind?.displayName ?? model.name) variant")
                .accessibilityIdentifier("settings_delete_\(model.id)")
            } else {
                Button("Use") {
                    viewModel.use(model)
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings_use_\(model.id)")
            }
        }
    }
}

// MARK: - Downloading control

private struct DownloadingControl: View {
    let progress: ModelManagerViewModel.DownloadProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let total = progress.totalBytes, total > 0 {
                ProgressView(value: Double(progress.downloadedBytes), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(width: 96)
                    .tint(AppTheme.statusProgressTint)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }

            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }
}
