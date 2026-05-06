import SwiftUI
import QwenVoiceCore
import AppKit

/// Unified Settings surface, modeled on macOS System Settings.
///
/// Single in-app surface that hosts model downloads + playback +
/// storage + about. Four grouped sections total:
///
/// 1. Models. One row per generation mode. Each row carries a
///    native popup `Picker` for variant selection (the System
///    Settings "Output device" idiom). The trailing action button
///    reflects the state of the currently-selected variant: Get,
///    Cancel + progress, Repair, or borderless trash when the
///    variant is active and on disk.
///
/// 2. Playback. Two toggles. Captions only where the toggle name
///    is not self-explanatory.
///
/// 3. Storage. Output directory + Application data, two compact
///    rows.
///
/// 4. About. Version line.
///
/// Mode color identity attaches to each row's leading 8 pt dot
/// rather than the section header — with one Models section, the
/// mode marker has to live on the row itself.
struct SettingsView: View {
    @EnvironmentObject private var viewModel: ModelManagerViewModel
    @Binding var highlightedModelID: String?

    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("outputDirectory") private var outputDirectory = ""
    @AppStorage(AudioService.smoothPlaybackKey) private var smoothPlayback = false

    @State private var flashedMode: GenerationMode?
    @State private var modelToDelete: TTSModel?
    @State private var showDeleteConfirmation = false

    // Empty FocusState declared so SwiftUI doesn't assert a
    // default tracked focus target on the form. Combined with
    // the first-responder reset below, this keeps the page
    // ring-free until the user explicitly Tabs into a control.
    @FocusState private var settingsFieldFocus: String?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Models") {
                    ForEach(GenerationMode.allCases, id: \.self) { mode in
                        ModeRow(
                            mode: mode,
                            viewModel: viewModel,
                            isFlashed: flashedMode == mode,
                            onDelete: { model in request(delete: model) }
                        )
                        .id(mode.rawValue)
                    }
                }

                Section("Playback") {
                    Toggle("Auto-play generated audio", isOn: $autoPlay)
                        .tint(AppTheme.preferences)
                        .accessibilityIdentifier("preferences_autoPlayToggle")

                    Toggle(isOn: $smoothPlayback) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Smooth playback")
                            Text("Adds a few seconds before audio starts; eliminates mid-playback pauses.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(AppTheme.preferences)
                    .accessibilityIdentifier("preferences_smoothPlaybackToggle")
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
                            Button("Choose…") { browseForOutputDirectory() }
                                .controlSize(.small)
                                .accessibilityIdentifier("preferences_browseButton")
                            if !outputDirectory.isEmpty {
                                Button("Reset") { outputDirectory = "" }
                                    .controlSize(.small)
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("preferences_outputResetButton")
                            }
                        }
                    }

                    // Application data row carries the version
                    // text inline so the dedicated About section is
                    // unnecessary. Settings stays at three sections;
                    // the About box (menu Vocello -> About Vocello)
                    // already covers full version detail in the
                    // standard macOS spot.
                    LabeledContent("Application data") {
                        HStack(spacing: 8) {
                            Text(appVersion)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.open(QwenVoiceApp.appSupportDir)
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("preferences_openFinderButton")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // Match the darker canvas background used by Generate
            // tabs. Without this, Form's grouped style paints its
            // own lighter gray panel that diverges from the rest
            // of the app's chrome.
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Settings")
            .accessibilityIdentifier("screen_settings")
            .task {
                await viewModel.refresh()
                focusHighlighted(using: proxy)

                // Clear the first popup's auto-assigned focus so
                // Settings doesn't open with a keyboard-focus ring.
                // System Settings on macOS waits for Tab; we mirror
                // that. Pressing Tab still surfaces the ring on the
                // next focus target — accessibility intact.
                try? await Task.sleep(nanoseconds: 50_000_000)
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            .onChange(of: highlightedModelID) { _, _ in
                focusHighlighted(using: proxy)
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
        if outputDirectory.isEmpty { return "Default" }
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

    private func focusHighlighted(using proxy: ScrollViewProxy) {
        guard let modelID = highlightedModelID,
              let model = TTSModel.model(id: modelID) else { return }
        let mode = model.mode
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            proxy.scrollTo(mode.rawValue, anchor: .center)
        }
        flashedMode = mode
        self.highlightedModelID = nil

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if flashedMode == mode { flashedMode = nil }
            }
        }
    }
}

// MARK: - Mode row

/// Single row for one generation mode. Native System Settings
/// idiom: leading label + mode-color dot, trailing native popup
/// for variant selection plus a context-sensitive action button.
private struct ModeRow: View {
    let mode: GenerationMode
    @ObservedObject var viewModel: ModelManagerViewModel
    let isFlashed: Bool
    let onDelete: (TTSModel) -> Void

    private var pair: (speed: TTSModel?, quality: TTSModel?) {
        viewModel.pairedVariants(for: mode)
    }

    /// The variant currently active for this mode, falling back
    /// to whichever variant exists if none is explicitly selected.
    private var activeVariant: TTSModel? {
        if let speed = pair.speed, viewModel.isActive(speed) { return speed }
        if let quality = pair.quality, viewModel.isActive(quality) { return quality }
        return pair.speed ?? pair.quality
    }

    /// Picker selection drives the active-variant preference.
    /// Reads from `viewModel.isActive`; writes via `viewModel.use`.
    private var selectionBinding: Binding<String?> {
        Binding<String?>(
            get: { activeVariant?.id },
            set: { newID in
                guard let newID else { return }
                if let speed = pair.speed, speed.id == newID { viewModel.use(speed) }
                if let quality = pair.quality, quality.id == newID { viewModel.use(quality) }
            }
        )
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                variantMenu
                    // Pinned width keeps the popup chevron at the
                    // same x across all three rows regardless of
                    // which variant is currently selected. Slightly
                    // narrower than before to leave room for the
                    // wider regular-size action button without the
                    // row wrapping to a second line.
                    .frame(width: 150)

                if let model = activeVariant {
                    ActionButton(
                        model: model,
                        viewModel: viewModel,
                        onDelete: { onDelete(model) }
                    )
                    // Fixed width on the action column so all rows'
                    // buttons share the same right edge regardless
                    // of whether the content is "Get", "Get 3.08 GB",
                    // a borderless trash icon, or "Cancel + progress".
                    .frame(width: 115, alignment: .trailing)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(AppTheme.modeColor(for: mode))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(mode.displayName)
            }
        }
        .listRowBackground(isFlashed ? Color.accentColor.opacity(0.10) : nil)
        .accessibilityIdentifier("settings_mode_\(mode.rawValue)")
    }

    /// Native macOS popup-style Menu. Closed state shows a terse
    /// `Speed (4-bit)` plus a small status icon (green check for
    /// the recommended variant, orange triangle for a hardware-
    /// risky one). The dropdown items repeat the icon and append
    /// the descriptor text so the user discovers which variant is
    /// recommended without leaving the popup.
    @ViewBuilder
    private var variantMenu: some View {
        Menu {
            if let speed = pair.speed {
                Button { viewModel.use(speed) } label: {
                    Label {
                        Text(dropdownText(for: speed))
                    } icon: {
                        statusGlyph(for: speed)
                    }
                }
            }
            if let quality = pair.quality {
                Button { viewModel.use(quality) } label: {
                    Label {
                        Text(dropdownText(for: quality))
                    } icon: {
                        statusGlyph(for: quality)
                    }
                }
            }
        } label: {
            // Spacer + maxWidth: .infinity forces the Menu's label
            // to fill the parent's fixed 175 pt frame so the
            // trailing chevron (rendered by SwiftUI outside this
            // HStack) anchors to the same x on every row,
            // regardless of how short or long the variant text is.
            HStack(spacing: 6) {
                Text(closedLabel)
                    .lineLimit(1)
                if let active = activeVariant {
                    statusGlyph(for: active)
                        .help(statusHint(for: active))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("\(mode.displayName) variant")
    }

    private var closedLabel: String {
        guard let active = activeVariant else { return "—" }
        let kind = active.variantKind?.displayName ?? active.name
        let bits = active.variantKind?.bitDepthLabel ?? ""
        return "\(kind) (\(bits))"
    }

    private func dropdownText(for model: TTSModel) -> String {
        let kind = model.variantKind?.displayName ?? model.name
        let bits = model.variantKind?.bitDepthLabel ?? ""
        let head = "\(kind) (\(bits))"
        if model.isHardwareRecommended {
            return "\(head) — Recommended"
        }
        if viewModel.isHardwareRisky(model) {
            return "\(head) — Heavy for your Mac"
        }
        return head
    }

    @ViewBuilder
    private func statusGlyph(for model: TTSModel) -> some View {
        if model.isHardwareRecommended {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if viewModel.isHardwareRisky(model) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func statusHint(for model: TTSModel) -> String {
        if model.isHardwareRecommended {
            return "Recommended for your Mac"
        }
        if viewModel.isHardwareRisky(model) {
            return "Heavy for your Mac. May exceed available memory."
        }
        return ""
    }
}

// MARK: - Action button

/// Trailing single primary control whose role flips with the
/// status of the currently-selected variant for this mode.
private struct ActionButton: View {
    let model: TTSModel
    @ObservedObject var viewModel: ModelManagerViewModel
    let onDelete: () -> Void

    /// Holder for the NSView that backs the Manage button's
    /// background, used as the anchor for the AppKit `NSMenu`'s
    /// popUp positioning.
    @State private var manageHostHolder = NSViewHostHolder()

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .checking
    }

    private var isDownloaded: Bool {
        if case .downloaded = status { return true }
        return false
    }

    private var isLiveActive: Bool {
        viewModel.isActive(model) && isDownloaded
    }

    var body: some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("settings_checking_\(model.id)")

        case .notDownloaded:
            HoverableActionButton(title: getButtonTitle) {
                Task { await viewModel.download(model) }
            }
            .accessibilityIdentifier("settings_get_\(model.id)")

        case .downloading(let progress):
            // Progress bar fills remaining width; cancel collapses
            // to a borderless `xmark.circle.fill` icon next to it
            // so the column stays at its 115 pt width without
            // wrapping the word "Cancel". Tooltip + a11y label
            // preserve the action's name for non-visual surfaces.
            HStack(spacing: 8) {
                if let total = progress.totalBytes, total > 0 {
                    ProgressView(value: Double(progress.downloadedBytes), total: Double(total))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                        .tint(AppTheme.statusProgressTint)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
                Button {
                    viewModel.cancelDownload(model)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .help("Cancel download")
                .accessibilityLabel("Cancel download")
                .accessibilityIdentifier("settings_cancel_\(model.id)")
            }

        case .repairAvailable:
            HoverableActionButton(title: "Repair", tint: .orange) {
                Task { await viewModel.download(model) }
            }
            .accessibilityIdentifier("settings_repair_\(model.id)")

        case .downloaded:
            // SwiftUI Button gives a byte-identical bezel to
            // Get/Repair. The dropdown is a real AppKit NSMenu
            // presented from the host NSView captured via
            // NSViewHostAccessor, so the menu has full system
            // chrome (vibrancy material, system rounded corners,
            // native item heights, native hover). The popover
            // approach we tried before rendered as plain SwiftUI
            // boxes and read as broken against the dark panel.
            Button {
                presentManageMenu()
            } label: {
                Text("Manage")
                    .frame(maxWidth: .infinity)
            }
            .background(NSViewHostAccessor(holder: manageHostHolder))
            .help("Manage \(model.variantKind?.displayName ?? model.name) variant")
            .accessibilityIdentifier("settings_manage_\(model.id)")
        }
    }

    private var getButtonTitle: String {
        if let size = viewModel.sizeText(for: model) {
            return "Get \(size)"
        }
        return "Get"
    }

    /// Build a real AppKit NSMenu and pop it up from the Manage
    /// button's host NSView. The closure-based items use a small
    /// retained `ClosureMenuItem` wrapper so we don't need a
    /// separate `@objc` controller.
    private func presentManageMenu() {
        guard let host = manageHostHolder.view else { return }

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(
            title: "Reveal in Finder",
            systemImage: "folder",
            handler: {
                let url = model.installDirectory(in: QwenVoiceApp.modelsDir)
                NSWorkspace.shared.open(url)
            }
        ))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(
            title: "Delete Model",
            systemImage: "trash",
            isDestructive: true,
            handler: onDelete
        ))

        // Popping up at the bottom-leading corner of the host
        // makes the menu appear directly under the button.
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: host.bounds.height + 2),
            in: host
        )
    }
}

// MARK: - AppKit menu bridge

/// Holds a weak reference to the NSView that backs the SwiftUI
/// Manage button so we can position an AppKit `NSMenu` against
/// it. `@State`-friendly because it's a class — SwiftUI keeps the
/// same instance across renders.
private final class NSViewHostHolder {
    weak var view: NSView?
}

/// Captures the SwiftUI Button's host NSView via a transparent
/// background view. SwiftUI mounts the NSView in the same
/// position as the Button itself, so its `bounds` are usable as
/// the menu anchor.
private struct NSViewHostAccessor: NSViewRepresentable {
    let holder: NSViewHostHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            holder.view = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

/// `NSMenuItem` subclass that retains a Swift closure and runs
/// it when the item is selected. Cleaner than a separate `@objc`
/// controller object — each item owns its own handler.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        isDestructive: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        super.init(
            title: title,
            action: #selector(invoke),
            keyEquivalent: ""
        )
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
        if isDestructive {
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ClosureMenuItem")
    }

    @objc private func invoke() {
        handler()
    }
}

// MARK: - Hoverable bordered button

/// Bordered button with a subtle hover highlight. macOS bordered
/// buttons in SwiftUI don't have a built-in hover state — only
/// press feedback — so the rest action surface reads as static
/// between clicks. `brightness(0.07)` on hover lifts every visible
/// pixel of the button (bezel, text, tint) without any
/// shape-matching gymnastics. Returns to resting brightness with a
/// short ease-out when the cursor leaves.
private struct HoverableActionButton: View {
    let title: String
    var tint: Color? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            action()
        } label: {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .tint(tint)
        .brightness(isHovering ? 0.12 : 0)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }
}
