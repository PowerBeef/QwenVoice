import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var viewModel: ModelManagerViewModel

    @Binding var highlightedModelID: String?

    @State private var flashedModelID: String?
    @State private var modelToDelete: TTSModel?
    @State private var showDeleteConfirmation = false

    private var installedModels: [TTSModel] {
        TTSModel.all.filter { model in
            if case .downloaded = viewModel.statuses[model.id] {
                return true
            }
            return false
        }
    }

    private var otherModels: [TTSModel] {
        TTSModel.all.filter { model in
            if case .downloaded = viewModel.statuses[model.id] {
                return false
            }
            return true
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !installedModels.isEmpty {
                    Section("Installed") {
                        ForEach(installedModels) { model in
                            ModelCard(
                                model: model,
                                viewModel: viewModel,
                                isHighlighted: flashedModelID == model.id,
                                onDelete: {
                                    modelToDelete = model
                                    showDeleteConfirmation = true
                                }
                            )
                            .id(model.id)
                        }
                    }
                }

                Section(installedModels.isEmpty ? "Available Models" : "Available To Download") {
                    ForEach(otherModels) { model in
                        ModelCard(
                            model: model,
                            viewModel: viewModel,
                            isHighlighted: flashedModelID == model.id,
                            onDelete: {
                                modelToDelete = model
                                showDeleteConfirmation = true
                            }
                        )
                        .id(model.id)
                    }
                }
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

struct ModelCard: View {
    let model: TTSModel
    @ObservedObject var viewModel: ModelManagerViewModel
    var isHighlighted: Bool = false
    var onDelete: (() -> Void)? = nil

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .checking
    }

    private var modeColor: Color {
        AppTheme.modeColor(for: model.mode)
    }

    private var usageLabel: String {
        "Used by \(model.mode.displayName)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(model.name, systemImage: model.mode.iconName)
                .font(.body.weight(.semibold))
                .foregroundStyle(modeColor)
                .accessibilityIdentifier("models_card_\(model.id)")

            VStack(alignment: .leading, spacing: 4) {
                Text(usageLabel)
                    .font(.footnote.weight(.medium))
                Text(model.folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusView
            }

            Spacer()
            actionView
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? modeColor.opacity(0.08) : .clear)
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .checking:
            Label("Checking local files...", systemImage: "hourglass")
                .font(.caption)
                .accessibilityIdentifier("models_checking_\(model.id)")
        case .notDownloaded:
            Text("Download this model to enable \(model.mode.displayName).")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 4) {
                if let totalBytes, totalBytes > 0 {
                    ProgressView(value: Double(downloadedBytes), total: Double(totalBytes))
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Preparing download...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .downloaded(let sizeBytes):
            Text("Ready - \(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))")
                .font(.caption)
                .foregroundStyle(modeColor)
        case .error:
            Text("Download failed. Retry to keep using \(model.mode.displayName).")
                .font(.caption)
                .foregroundStyle(.red)
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
            .tint(modeColor)
            .accessibilityIdentifier("models_download_\(model.id)")
        case .downloading:
            Button("Cancel") {
                viewModel.cancelDownload(model)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .downloaded:
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("models_delete_\(model.id)")
        case .error:
            Button("Retry") {
                Task { await viewModel.download(model) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(modeColor)
            .accessibilityIdentifier("models_retry_\(model.id)")
        }
    }
}
