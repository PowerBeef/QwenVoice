import SwiftUI
import QwenVoiceCore

struct ModelsView: View {
    @EnvironmentObject private var viewModel: ModelManagerViewModel

    @Binding var highlightedModelID: String?

    @State private var flashedModelID: String?
    @State private var modelToDelete: TTSModel?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ModelsIntroLine(deviceClass: viewModel.deviceClass)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 16))
                }
                .listSectionSeparator(.hidden)

                ForEach(GenerationMode.allCases, id: \.self) { mode in
                    Section {
                        ModelSectionHeader(mode: mode)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 4, trailing: 0))

                        let pair = viewModel.pairedVariants(for: mode)
                        ModeVariantsRow(
                            mode: mode,
                            speed: pair.speed,
                            quality: pair.quality,
                            viewModel: viewModel,
                            highlightedModelID: flashedModelID,
                            onDeleteRequest: { model in
                                modelToDelete = model
                                showDeleteConfirmation = true
                            }
                        )
                        .id(mode.rawValue)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 16))
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
        // Resolve the model id back to its mode so we can scroll
        // to the row that owns it (the row id is the mode's
        // raw value now, not the per-variant id).
        let scrollAnchor: String? = {
            if let model = TTSModel.model(id: modelID) {
                return model.mode.rawValue
            }
            return nil
        }()
        if let scrollAnchor {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                proxy.scrollTo(scrollAnchor, anchor: .center)
            }
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

/// Mode-grouped section header. Three layers of identity:
/// the mode name in `.title3` weight; a 26×2 underscore in
/// the mode color directly under it; a one-sentence
/// description below in secondary text, lifted from
/// PRODUCT.md so it stays on-brand. The description gives the
/// section gravitas the underscore alone can't carry — without
/// it the pills below read as orphan controls.
private struct ModelSectionHeader: View {
    let mode: GenerationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mode.displayName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)

            Capsule(style: .continuous)
                .fill(AppTheme.modeColor(for: mode))
                .frame(width: 26, height: 2)
                .opacity(0.85)
                .accessibilityHidden(true)

            Text(Self.description(for: mode))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.displayName). \(Self.description(for: mode))")
    }

    private static func description(for mode: GenerationMode) -> String {
        switch mode {
        case .custom: return "Generate with a preset speaker."
        case .design: return "Describe a voice in natural language."
        case .clone: return "Match a 10 to 20 second reference clip."
        }
    }
}

// MARK: - Top-of-panel intro line

/// One-sentence framing above the first section. Sets the
/// page's purpose so the pills don't read as orphan controls,
/// and personalizes the recommendation language to the user's
/// Mac memory tier so it never speaks past the reader.
private struct ModelsIntroLine: View {
    let deviceClass: NativeDeviceMemoryClass

    var body: some View {
        Text(introText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("models_intro")
    }

    private var introText: String {
        switch deviceClass {
        case .floor8GBMac:
            return "Pick the variant for each mode. The 4-bit version runs comfortably on your Mac. The 8-bit version is sharper but heavier than your Mac comfortably handles."
        case .mid16GBMac:
            return "Pick the variant for each mode. The 8-bit version is sharper; the 4-bit version is faster and lighter."
        case .highMemoryMac:
            return "Pick the variant for each mode. The 8-bit version is recommended for your Mac. The 4-bit version is faster but lower fidelity."
        case .iPhonePro:
            // Mac-only surface; this branch is unreachable in production but
            // keeps the switch exhaustive without a default that would mute a
            // future enum case.
            return "Pick the variant for each mode."
        }
    }
}

// MARK: - Mode-grouped row (both variants on one line)

/// One row per generation mode. Renders both variants as
/// tappable pills sharing the same horizontal anchor, and
/// surfaces a single secondary line for an in-flight download
/// or a most-recent error message — whichever variant they
/// belong to.
private struct ModeVariantsRow: View {
    let mode: GenerationMode
    let speed: TTSModel?
    let quality: TTSModel?
    @ObservedObject var viewModel: ModelManagerViewModel
    let highlightedModelID: String?
    let onDeleteRequest: (TTSModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                if let speed {
                    pillColumn(for: speed)
                }
                if let quality {
                    pillColumn(for: quality)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)   // breathing room for the corner badges

            if let progressContext = inflightDownloadContext {
                DownloadProgressLine(progress: progressContext.progress)
                    .padding(.leading, 4)
                    .accessibilityIdentifier("models_progress_\(progressContext.modelID)")
            } else if let summary = statusSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("models_summary_\(mode.rawValue)")
            }

            if let surfacedError {
                Text(surfacedError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 4)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode.displayName)
    }

    /// One-sentence summary of the row's combined state. Suppressed
    /// during in-flight downloads (the progress line carries that
    /// state) and during repair states (the error text takes priority).
    /// Reads as a native macOS settings caption: concrete numbers, plain
    /// verbs, no marketing volume.
    private var statusSummary: String? {
        // Repair always wins — a missing-files row is the most
        // actionable thing on the page.
        for model in orderedVariants {
            if case .repairAvailable(_, let missingPaths, _) = viewModel.statuses[model.id] {
                let kind = model.variantKind?.bitDepthLabel ?? model.name
                let count = missingPaths.count
                if count > 0 {
                    return "\(kind) needs repair: \(count) required file\(count == 1 ? "" : "s") missing."
                }
                return "\(kind) needs repair: local files are incomplete."
            }
        }

        let speedDownloaded = isDownloaded(speed)
        let qualityDownloaded = isDownloaded(quality)
        let activeKind: TTSModelVariantKind? = orderedVariants
            .first(where: { viewModel.isActive($0) && isDownloaded($0) })?
            .variantKind

        switch (speedDownloaded, qualityDownloaded) {
        case (false, false):
            // Neither installed — recommend the safe choice with its size.
            if let recommended = orderedVariants.first(where: { $0.isHardwareRecommended }),
               let kind = recommended.variantKind?.bitDepthLabel {
                if let size = viewModel.sizeText(for: recommended) {
                    return "Not installed. \(kind) (\(size)) recommended for your Mac."
                }
                return "Not installed. \(kind) recommended for your Mac."
            }
            return "Not installed."

        case (true, false):
            let qualitySize = quality.flatMap(viewModel.sizeText)
            let qualityFragment = qualitySize.map { " 8-bit (\($0)) available" } ?? " 8-bit available"
            let qualityRisky = quality.map(viewModel.isHardwareRisky) ?? false
            let qualityTail = qualityRisky
                ? ", but heavier than your Mac comfortably handles."
                : "."
            let speedHead = (activeKind == .speed) ? "4-bit active." : "4-bit installed."
            return "\(speedHead)\(qualityFragment)\(qualityTail)"

        case (false, true):
            let speedSize = speed.flatMap(viewModel.sizeText)
            let speedFragment = speedSize.map { " 4-bit (\($0)) available." } ?? " 4-bit available."
            let qualityHead = (activeKind == .quality) ? "8-bit active." : "8-bit installed."
            return "\(qualityHead)\(speedFragment)"

        case (true, true):
            switch activeKind {
            case .speed:
                return "4-bit active. 8-bit installed but inactive."
            case .quality:
                return "8-bit active. 4-bit installed but inactive."
            case .none:
                return "Both variants installed. Click one to make it active."
            }
        }
    }

    private func isDownloaded(_ model: TTSModel?) -> Bool {
        guard let model else { return false }
        if case .downloaded = viewModel.statuses[model.id] { return true }
        return false
    }

    /// Wraps a pill with a small caption directly under it. The
    /// caption renders as "Recommended" (green) for the
    /// hardware-recommended variant and as a hidden placeholder
    /// for the non-recommended variant, so both columns share the
    /// same vertical height — otherwise the recommended column
    /// would sit slightly lower than its sibling and the row
    /// would look uneven.
    @ViewBuilder
    private func pillColumn(for model: TTSModel) -> some View {
        VStack(alignment: .center, spacing: 3) {
            VariantPill(
                model: model,
                viewModel: viewModel,
                isHighlighted: highlightedModelID == model.id,
                onDeleteRequest: { onDeleteRequest(model) }
            )

            if model.isHardwareRecommended {
                Text("Recommended")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.green)
                    .accessibilityHidden(true)
            } else {
                // Invisible spacer with the same line metrics so
                // the pill row stays balanced even when only one
                // variant carries the caption.
                Text(" ")
                    .font(.caption2.weight(.semibold))
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
    }

    private var orderedVariants: [TTSModel] {
        [speed, quality].compactMap { $0 }
    }

    private var inflightDownloadContext: (modelID: String, progress: ModelManagerViewModel.DownloadProgress)? {
        for model in orderedVariants {
            if case .downloading(let progress) = viewModel.statuses[model.id] {
                return (model.id, progress)
            }
        }
        return nil
    }

    private var surfacedError: String? {
        for model in orderedVariants {
            switch viewModel.statuses[model.id] {
            case .notDownloaded(let message):
                if let message, !message.isEmpty { return message }
            case .repairAvailable(_, _, let message):
                if let message, !message.isEmpty { return message }
            default:
                break
            }
        }
        return nil
    }
}

// MARK: - Variant pill

/// One tappable pill per variant. Mode color is the variant's
/// identity (always present), with state expressed through fill
/// vs. outline vs. ghost. A small icon at the top-trailing
/// corner marks the hardware-recommended variant (★) or, when
/// the variant would be too heavy for this Mac's RAM, a
/// warning (⚠). Tap is the action: download / make-active /
/// cancel / repair. Right-click offers Delete on downloaded
/// variants. Hover shows a tooltip with size + state guidance,
/// including the warning explanation for risky variants.
private struct VariantPill: View {
    let model: TTSModel
    @ObservedObject var viewModel: ModelManagerViewModel
    let isHighlighted: Bool
    let onDeleteRequest: () -> Void

    @State private var isHovering: Bool = false

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .checking
    }

    private var modeColor: Color {
        AppTheme.modeColor(for: model.mode)
    }

    private var bitDepthLabel: String {
        model.variantKind?.bitDepthLabel ?? "—"
    }

    private var isActive: Bool { viewModel.isActive(model) }
    private var isRecommended: Bool { model.isHardwareRecommended }
    private var isRisky: Bool { viewModel.isHardwareRisky(model) }

    private var isDownloaded: Bool {
        if case .downloaded = status { return true }
        return false
    }
    private var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }
    private var needsRepair: Bool {
        if case .repairAvailable = status { return true }
        return false
    }
    private var isChecking: Bool {
        if case .checking = status { return true }
        return false
    }

    private var sizeText: String? {
        viewModel.sizeText(for: model)
    }

    var body: some View {
        Button(action: handleTap) {
            ZStack(alignment: .topTrailing) {
                pillContent
                badgeOverlay
                    .offset(x: 4, y: -4)
                    .allowsHitTesting(false)
            }
            // Reserve room above and to the trailing edge of the
            // pill so the corner badge never gets clipped by the
            // row's listRowInsets.
            .padding(.top, 4)
            .padding(.trailing, 4)
        }
        .buttonStyle(.plain)
        .help(tooltipText)
        .contextMenu {
            if isDownloaded || needsRepair {
                Button(role: .destructive, action: onDeleteRequest) {
                    Label("Delete \(bitDepthLabel) Variant", systemImage: "trash")
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("models_pill_\(model.id)")
    }

    private var pillContent: some View {
        HStack(spacing: 6) {
            Text(bitDepthLabel)
                .font(.callout.weight(isLiveActive ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(textForeground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            stateGlyph
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minWidth: 76)
        .background(pillBackground)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        }
        .overlay {
            if isHighlighted {
                Capsule(style: .continuous)
                    .stroke(AppTheme.accent, lineWidth: 2)
            }
        }
        .scaleEffect(isHovering && !isLiveActive ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    @ViewBuilder
    private var stateGlyph: some View {
        if isDownloading {
            ProgressView()
                .controlSize(.mini)
                .tint(modeColor)
        } else if needsRepair {
            Image(systemName: "wrench.adjustable.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
        } else if isChecking {
            Image(systemName: "hourglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var badgeOverlay: some View {
        if isRisky {
            cornerBadge(systemName: "exclamationmark.triangle.fill", tint: .orange)
        } else if isRecommended {
            // Green check decouples the recommendation from the
            // mode color so it reads as "good / approved"
            // regardless of which mode the user is on. Pairs with
            // the small "Recommended" caption below the pill.
            cornerBadge(systemName: "checkmark.circle.fill", tint: .green)
        }
    }

    private func cornerBadge(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(3)
            .background {
                Circle()
                    .fill(.background)
                    .overlay {
                        Circle().stroke(tint.opacity(0.35), lineWidth: 0.5)
                    }
            }
    }

    /// `true` only when the variant is BOTH the user's selected
    /// active variant AND actually present on disk. We deliberately
    /// don't promote a not-yet-downloaded variant to the filled
    /// treatment even when it's the active fallback (recommended
    /// for the hardware): the filled pill should always read as
    /// "this is what generation is running on", not "this would
    /// be active if you installed it".
    private var isLiveActive: Bool { isActive && isDownloaded }

    @ViewBuilder
    private var pillBackground: some View {
        if isLiveActive {
            modeColor
        } else if isDownloaded {
            modeColor.opacity(0.12)
        } else if isDownloading || needsRepair {
            modeColor.opacity(0.06)
        } else {
            // not downloaded — ghost
            Color.clear
        }
    }

    private var textForeground: Color {
        if isLiveActive { return .white }
        if isDownloaded || isDownloading || needsRepair { return modeColor }
        return .secondary
    }

    private var borderColor: Color {
        if isLiveActive { return Color.clear }
        if needsRepair { return Color.orange.opacity(0.7) }
        if isDownloaded || isDownloading { return modeColor.opacity(0.7) }
        return modeColor.opacity(0.35)
    }

    private var borderWidth: CGFloat {
        isLiveActive ? 0 : 1
    }

    private var tooltipText: String {
        var lines: [String] = []
        let kindName = model.variantKind?.displayName ?? model.name
        let sizePart = sizeText ?? "Size unknown until download starts"
        lines.append("\(kindName) (\(bitDepthLabel)) — \(sizePart)")

        switch status {
        case .checking:
            lines.append("Checking local files…")
        case .notDownloaded(let message):
            if let message, !message.isEmpty {
                lines.append(message)
            } else {
                lines.append("Click to download.")
            }
        case .downloading:
            lines.append("Downloading… click to cancel.")
        case .repairAvailable(_, _, let message):
            lines.append("Local files are incomplete. Click to repair.")
            if let message, !message.isEmpty {
                lines.append(message)
            }
        case .downloaded:
            if isActive {
                lines.append("Active variant. Right-click to delete.")
            } else {
                lines.append("Click to make this the active variant.")
            }
        }

        if isRisky {
            lines.append("⚠ This variant may exceed the memory available on your Mac. Generation could fail or be very slow. The 4-bit variant is the safe choice for your hardware.")
        } else if isRecommended {
            lines.append("✓ Recommended for your Mac.")
        }

        return lines.joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        var parts: [String] = [
            model.mode.displayName,
            model.variantKind?.displayName ?? model.name,
            bitDepthLabel
        ]
        if isActive { parts.append("Active") }
        else if isDownloaded { parts.append("Downloaded") }
        else if isDownloading { parts.append("Downloading") }
        else if needsRepair { parts.append("Needs repair") }
        else if isChecking { parts.append("Checking") }
        else { parts.append("Not downloaded") }
        if isRecommended { parts.append("Recommended") }
        if isRisky { parts.append("Hardware warning") }
        if let sizeText { parts.append(sizeText) }
        return parts.joined(separator: ", ")
    }

    private func handleTap() {
        switch status {
        case .checking:
            break
        case .notDownloaded:
            Task { await viewModel.download(model) }
        case .downloading:
            viewModel.cancelDownload(model)
        case .repairAvailable:
            Task { await viewModel.download(model) }
        case .downloaded:
            if !isActive {
                viewModel.use(model)
            }
        }
    }
}

// MARK: - Download progress line

/// Tight inline detail for an in-flight download. Shared by all
/// modes; rendered once per row, only when one of that row's
/// variants is mid-download.
private struct DownloadProgressLine: View {
    let progress: ModelManagerViewModel.DownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let totalBytes = progress.totalBytes, totalBytes > 0 {
                ProgressView(value: Double(progress.downloadedBytes), total: Double(totalBytes))
                    .progressViewStyle(.linear)
                    .tint(AppTheme.statusProgressTint)
                    .frame(maxWidth: 280)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AppTheme.statusProgressTint)
                    .frame(maxWidth: 280)
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
