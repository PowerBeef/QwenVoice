import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var viewModel: ModelManagerViewModel

    let isActive: Bool
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
                        }
                    }
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
            .task(id: isActive) {
                guard isActive else { return }
                await viewModel.refresh()
                focusHighlightedModel(using: proxy)
            }
            .onChange(of: highlightedModelID) { _, _ in
                guard isActive else { return }
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
        case .notDownloaded:
            Text("Download to enable \(model.mode.displayName).")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 4) {
                if let totalBytes, totalBytes > 0 {
                    ProgressView(value: Double(downloadedBytes), total: Double(totalBytes))
                        .tint(AppTheme.accent)
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .tint(AppTheme.accent)
                    Text("Preparing download...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .tint(AppTheme.accent)
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
            .tint(AppTheme.accent)
            .accessibilityIdentifier("models_retry_\(model.id)")
        }
    }

    @ViewBuilder
    private var modeIcon: some View {
        #if QW_UI_LIQUID
        if #available(macOS 26, *) {
            Color.clear
                .frame(width: 34, height: 34)
                .glassEffect(.regular.tint(AppTheme.accent), in: .rect(cornerRadius: 8))
                .overlay {
                    Image(systemName: model.mode.iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
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
