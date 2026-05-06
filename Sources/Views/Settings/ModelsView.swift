import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var viewModel: ModelManagerViewModel

    @Binding var highlightedModelID: String?

    @State private var flashedModelID: String?
    @State private var modelToDelete: TTSModel?
    @State private var showDeleteConfirmation = false

    private var modeGroups: [(GenerationMode, [TTSModel])] {
        GenerationMode.allCases.map { mode in
            (mode, TTSModel.all.filter { $0.mode == mode })
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // The header lives inside the section's content (not
                // the `header:` slot) so the row-level
                // `.listRowSeparator(.hidden)` modifier actually
                // suppresses the divider — `.listStyle(.inset)` on
                // macOS draws a separator below `header:` views and
                // ignores attempts to hide it from the
                // `.listSectionSeparator` chain.
                ForEach(modeGroups, id: \.0) { (mode, modelsForMode) in
                    Section {
                        ModelSectionHeader(mode: mode)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 6, trailing: 0))

                        ForEach(modelsForMode) { model in
                            ModelRow(
                                model: model,
                                viewModel: viewModel,
                                isActive: viewModel.isActive(model),
                                isRecommended: model.isHardwareRecommended,
                                isHighlighted: flashedModelID == model.id,
                                onUse: { viewModel.use(model) },
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

// MARK: - Section header

/// Mode-grouped section header. The mode name carries the row in
/// `.title3` weight; a 28×2 underscore in the mode color sits
/// beneath the text as a quiet identity mark, replacing the
/// earlier leading dot. PRODUCT.md treats Vocello gold + Voice
/// Design lavender + Voice Cloning terracotta as whisper-tinted
/// peripherals, never wallpaper, so the underscore stays narrow
/// and tucked beneath the label.
private struct ModelSectionHeader: View {
    let mode: GenerationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(mode.displayName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)

            Capsule(style: .continuous)
                .fill(AppTheme.modeColor(for: mode))
                .frame(width: 26, height: 2)
                .opacity(0.85)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mode.displayName)
    }
}

// MARK: - Row

struct ModelRow: View {
    let model: TTSModel
    let viewModel: ModelManagerViewModel
    let isActive: Bool
    let isRecommended: Bool
    var isHighlighted: Bool = false
    var onUse: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovering: Bool = false

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .checking
    }

    private var variantName: String {
        model.variantKind?.displayName ?? "Default"
    }

    private var bitDepthLabel: String? {
        model.variantKind?.bitDepthLabel
    }

    private var sizeText: String? {
        viewModel.sizeText(for: model)
    }

    private var modeColor: Color {
        AppTheme.modeColor(for: model.mode)
    }

    private var rowAccessibilityLabel: String {
        var parts: [String] = [model.mode.displayName, variantName]
        if let bitDepthLabel { parts.append(bitDepthLabel) }
        if let sizeText { parts.append(sizeText) }
        if isRecommended { parts.append("Recommended") }
        if isActive { parts.append("Active") }
        switch status {
        case .checking: parts.append("Checking")
        case .downloading: parts.append("Downloading")
        case .repairAvailable: parts.append("Needs repair")
        case .notDownloaded: parts.append("Not downloaded")
        case .downloaded: break
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            primaryLine
            secondaryLineContent
                .padding(.leading, 10)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(rowSurface)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityIdentifier("models_card_\(model.id)")
    }

    /// The single anchor line for every healthy state. Variant
    /// name carries the row; bit-depth and size sit alongside as
    /// quiet metadata; recommended / active live in the trailing
    /// indicator group; the action button anchors the right edge.
    private var primaryLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(variantName)
                .font(.body.weight(isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(modeColor) : AnyShapeStyle(Color.primary))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 60, alignment: .leading)
                .help(model.folder)

            if let bitDepthLabel {
                Text(bitDepthLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let sizeText {
                Text(separator)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(sizeText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 8)

            indicators

            actionView
                .frame(minWidth: 92, alignment: .trailing)
        }
    }

    private var separator: String { "·" }

    @ViewBuilder
    private var indicators: some View {
        if isRecommended {
            ModelBadge(text: "Recommended", tint: AppTheme.accent)
        }
        if isActive {
            ModelBadge(text: "Active", tint: modeColor)
        }
    }

    /// Layered surface for the row: a base resting fill, a hover
    /// lift, an active backdrop, and the deep-link flash overlay.
    /// On macOS 26 with Liquid Glass available, the active row
    /// upgrades to a tinted glass material. On older macOS or
    /// with Reduce Transparency, the legacy fallback is a flat
    /// mode-tinted fill: the visual stays legible without glass.
    @ViewBuilder
    private var rowSurface: some View {
        ZStack {
            #if QW_UI_LIQUID
            if #available(macOS 26, *) {
                if isActive {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.clear)
                        .glassEffect(
                            .regular.tint(modeColor.opacity(0.18)),
                            in: .rect(cornerRadius: 10)
                        )
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(modeColor.opacity(0.05))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(modeColor.opacity(0.18), lineWidth: 0.5)
                        }
                } else {
                    Color.clear
                }
            } else {
                rowSurfaceLegacy
            }
            #else
            rowSurfaceLegacy
            #endif

            if isHighlighted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.accent.opacity(0.22), lineWidth: 1)
                    }
            }
        }
    }

    @ViewBuilder
    private var rowSurfaceLegacy: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(modeColor.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(modeColor.opacity(0.22), lineWidth: 0.5)
                }
        } else if isHovering {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(modeColor.opacity(0.05))
        } else {
            Color.clear
        }
    }

    /// Inline secondary content shown only for the abnormal
    /// states that genuinely benefit from extra explanation:
    /// download progress, repair details, and surfaced error
    /// messages. Healthy states (checking, notDownloaded with no
    /// error, downloaded) collapse to the single primary line.
    @ViewBuilder
    private var secondaryLineContent: some View {
        switch status {
        case .checking:
            EmptyView()
        case .notDownloaded(let message):
            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .downloading(let progress):
            DownloadProgressLine(progress: progress)
        case .repairAvailable(let sizeBytes, let missingRequiredPaths, let message):
            VStack(alignment: .leading, spacing: 2) {
                if !missingRequiredPaths.isEmpty {
                    Text("Missing \(missingRequiredPaths.count) required file\(missingRequiredPaths.count == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if sizeBytes > 0 {
                    Text("Local files are incomplete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        case .downloaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("models_checking_\(model.id)")
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
            if isActive {
                // Quieter trash on the Active row. The row itself
                // already telegraphs "this is your selection" via
                // the mode-tinted backdrop and the Active badge;
                // a borderless icon-only button keeps the action
                // available without competing with the indicator
                // strip.
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Delete \(model.name)")
                .accessibilityIdentifier("models_delete_\(model.id)")
            } else {
                Button("Use") {
                    onUse?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(AppTheme.accent)
                .accessibilityIdentifier("models_use_\(model.id)")
            }
        }
    }
}

// MARK: - Download progress line

/// Tight inline detail for an in-flight download. Replaces the
/// prior multi-line progress block; condenses the same data into
/// a single readable line plus a thin progress bar.
private struct DownloadProgressLine: View {
    let progress: ModelManagerViewModel.DownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let totalBytes = progress.totalBytes, totalBytes > 0 {
                ProgressView(value: Double(progress.downloadedBytes), total: Double(totalBytes))
                    .progressViewStyle(.linear)
                    .tint(AppTheme.statusProgressTint)
                    .frame(maxWidth: 240)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AppTheme.statusProgressTint)
                    .frame(maxWidth: 240)
            }

            HStack(spacing: 6) {
                Text(progress.phase.displayName)
                    .foregroundStyle(.secondary)

                if let totalBytes = progress.totalBytes, totalBytes > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: progress.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
                    )
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                if progress.isStalled {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Waiting")
                        .foregroundStyle(.secondary)
                } else if let bytesPerSecond = progress.bytesPerSecond, bytesPerSecond > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("\(ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file))/s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let totalFiles = progress.totalFiles, totalFiles > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("File \(min(progress.completedFiles + 1, totalFiles)) of \(totalFiles)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }
}

// MARK: - Badge

private struct ModelBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background {
                Capsule()
                    .fill(tint.opacity(0.14))
            }
    }
}

private extension ModelManagerViewModel.DownloadProgress.Phase {
    var displayName: String {
        switch self {
        case .downloading:
            return "Downloading"
        case .interrupted:
            return "Interrupted"
        case .resuming:
            return "Resuming"
        case .verifying:
            return "Verifying"
        case .installing:
            return "Installing"
        }
    }
}
