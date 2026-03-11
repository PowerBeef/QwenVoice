import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var viewModel: ModelManagerViewModel
    @Binding var highlightedModelID: String?
    @State private var flashedModelID: String?
    @State private var modelToDelete: TTSModel?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutConstants.sectionSpacing) {
                    GenerationHeaderView(
                        title: "Models",
                        subtitle: "Each model powers one generation workflow. Download what you need.",
                        titleAccessibilityIdentifier: "models_title"
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(TTSModel.all) { model in
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
                .padding(LayoutConstants.canvasPadding)
                .contentColumn()
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
        HStack(spacing: 12) {
            Image(systemName: model.mode.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(modeColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.name)
                    .font(.system(size: 14, weight: .semibold))

                Text(usageLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(modeColor)

                Text(model.folder)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                switch status {
                case .checking:
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: 200, alignment: .leading)
                        Text("Checking local files...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("models_checking_\(model.id)")
                case .notDownloaded:
                    Text("Download this model to enable \(model.mode.displayName).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .downloading(let downloadedBytes, let totalBytes):
                    VStack(alignment: .leading, spacing: 2) {
                        if let totalBytes, totalBytes > 0 {
                            let progress = min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
                            let formattedDL = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
                            let formattedTotal = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(modeColor.opacity(0.18))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(modeColor)
                                        .frame(width: max(6, geo.size.width * progress))
                                }
                            }
                            .frame(maxWidth: 200, maxHeight: 6)

                            Text(progress >= 1.0 ? "Finalizing..." : "\(formattedDL) / \(formattedTotal)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: 200, alignment: .leading)
                            Text("Preparing download...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                case .downloaded(let sizeBytes):
                    Text("Ready — \(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))")
                        .font(.caption)
                        .foregroundColor(modeColor)
                case .error:
                    Text("Download failed. Retry to keep using \(model.mode.displayName).")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Spacer()

            switch status {
            case .checking:
                EmptyView()
            case .notDownloaded:
                Button("Download") {
                    Task { await viewModel.download(model) }
                }
                .buttonStyle(.borderedProminent)
                .tint(modeColor)
                .controlSize(.small)
                .accessibilityIdentifier("models_download_\(model.id)")
            case .downloading:
                Button("Cancel") {
                    viewModel.cancelDownload(model)
                }
                .controlSize(.small)
            case .downloaded:
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .accessibilityIdentifier("models_delete_\(model.id)")
            case .error:
                Button("Retry") {
                    Task { await viewModel.download(model) }
                }
                .buttonStyle(.borderedProminent)
                .tint(modeColor)
                .controlSize(.small)
                .accessibilityIdentifier("models_retry_\(model.id)")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isHighlighted ? modeColor.opacity(0.10) : AppTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isHighlighted ? modeColor.opacity(0.30) : AppTheme.cardStroke, lineWidth: isHighlighted ? 1.5 : LayoutConstants.cardBorderWidth)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models_card_\(model.id)")
    }
}
