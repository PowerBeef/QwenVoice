import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var viewModel: ModelManagerViewModel

    @Binding var highlightedModelID: String?

    @State private var flashedModelID: String?
    @State private var modelToDelete: TTSModel?
    @State private var showDeleteConfirmation = false

    private var installedModels: [TTSModel] {
        TTSModel.all.filter(isInstalledModel)
    }

    private var otherModels: [TTSModel] {
        TTSModel.all.filter { !isInstalledModel($0) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !installedModels.isEmpty {
                    Section("Installed") {
                        ForEach(installedModels) { model in
                            ModelRow(
                                model: model,
                                viewModel: viewModel,
                                isHighlighted: flashedModelID == model.id,
                                onDelete: {
                                    modelToDelete = model
                                    showDeleteConfirmation = true
                                }
                            )
                            .id(model.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listSectionSeparator(.hidden)
                }

                Section("Available To Download") {
                    ForEach(otherModels) { model in
                        ModelRow(
                            model: model,
                            viewModel: viewModel,
                            isHighlighted: flashedModelID == model.id,
                            onDelete: {
                                modelToDelete = model
                                showDeleteConfirmation = true
                            }
                        )
                        .id(model.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listSectionSeparator(.hidden)
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                Text("Models")
                    .font(.system(size: 1))
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("models_title")
            }
            .accessibilityIdentifier("screen_models")
            .task {
                await viewModel.refresh()
                focusHighlightedModel(using: proxy)
            }
            .onChange(of: highlightedModelID) { _, _ in
                focusHighlightedModel(using: proxy)
            }
        }
        .alert("Delete Model?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let model = modelToDelete {
                    viewModel.delete(model)
                }
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
}

private extension ModelsView {
    func isInstalledModel(_ model: TTSModel) -> Bool {
        switch viewModel.statuses[model.id] {
        case .downloaded:
            return true
        default:
            return false
        }
    }

    func focusHighlightedModel(using proxy: ScrollViewProxy) {
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
                if flashedModelID == modelID {
                    flashedModelID = nil
                }
            }
        }
    }
}

struct ModelRow: View {
    let model: TTSModel
    let viewModel: ModelManagerViewModel
    var isHighlighted: Bool = false
    var onDelete: (() -> Void)? = nil

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .checking
    }

    private var usageLabel: String {
        "Used by \(model.mode.displayName)"
    }

    private var variantLabel: String {
        if model.folder.localizedCaseInsensitiveContains("4bit") {
            return "Speed variant"
        }
        if model.folder.localizedCaseInsensitiveContains("8bit") {
            return "Quality variant"
        }
        return "Model variant"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            modeIcon

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(usageLabel)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(variantLabel)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(model.folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                statusView
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 8) {
                actionView
            }
            .frame(minWidth: 92, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowHighlight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models_card_\(model.id)")
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .checking:
            Label("Checking local files...", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("models_checking_\(model.id)")
        case .notDownloaded(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Download to enable \(model.mode.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.phase.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let totalBytes = progress.totalBytes, totalBytes > 0 {
                    ProgressView(value: Double(progress.downloadedBytes), total: Double(totalBytes))
                        .tint(AppTheme.statusProgressTint)
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .tint(AppTheme.statusProgressTint)
                    Text("Preparing download...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let totalFiles = progress.totalFiles, totalFiles > 0 {
                    Text("File \(min(progress.completedFiles + 1, totalFiles)) of \(totalFiles)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if progress.isStalled {
                    Text("Waiting for network activity...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let bytesPerSecond = progress.bytesPerSecond, bytesPerSecond > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file))/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .repairAvailable(let sizeBytes, let missingRequiredPaths, let message):
            VStack(alignment: .leading, spacing: 4) {
                if !missingRequiredPaths.isEmpty {
                    Text("Missing \(missingRequiredPaths.count) required file\(missingRequiredPaths.count == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Local files are incomplete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if sizeBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        case .downloaded(let sizeBytes):
            HStack(spacing: 8) {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(AppTheme.accent)

                Text(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch status {
        case .checking:
            EmptyView()
        case .notDownloaded:
            Button("Download") {
                Task { await viewModel.download(model) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(AppTheme.accent)
            .accessibilityIdentifier("models_download_\(model.id)")
        case .downloading:
            Button("Cancel") {
                viewModel.cancelDownload(model)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .repairAvailable:
            Button("Repair") {
                Task { await viewModel.download(model) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(AppTheme.accent)
            .accessibilityIdentifier("models_retry_\(model.id)")
        case .downloaded:
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("models_delete_\(model.id)")
        }
    }

    @ViewBuilder
    private var modeIcon: some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            Color.clear
                .frame(width: 34, height: 34)
                .glassEffect(.regular.tint(AppTheme.smokedGlassTint), in: .rect(cornerRadius: 8))
                .overlay {
                    Image(systemName: model.mode.iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
        } else {
            modeIconLegacy
        }
        #else
        modeIconLegacy
        #endif
    }

    private var modeIconLegacy: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AppTheme.accent.opacity(isHighlighted ? 0.14 : 0.08))
            .frame(width: 34, height: 34)
            .overlay {
                Image(systemName: model.mode.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
    }

    @ViewBuilder
    private var rowHighlight: some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(AppTheme.accent), in: .rect(cornerRadius: 10))
            } else {
                Color.clear
            }
        } else {
            rowHighlightLegacy
        }
        #else
        rowHighlightLegacy
        #endif
    }

    private var rowHighlightLegacy: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHighlighted ? AppTheme.accent.opacity(0.08) : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHighlighted ? AppTheme.accent.opacity(0.18) : .clear, lineWidth: 1)
            }
    }
}

private extension ModelManagerViewModel.DownloadProgress.Phase {
    var displayName: String {
        switch self {
        case .downloading:
            return "Downloading model..."
        case .interrupted:
            return "Download interrupted."
        case .resuming:
            return "Resuming download..."
        case .verifying:
            return "Verifying model files..."
        case .installing:
            return "Installing model..."
        }
    }
}
