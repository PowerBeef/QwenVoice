import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QwenVoiceCore

@MainActor
private enum IOSSettingsSupportInfo {
    static var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

@MainActor
private enum IOSSettingsFormatters {
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func fileSize(_ bytes: Int64) -> String {
        byteCount.string(fromByteCount: bytes)
    }
}

struct IOSSettingsContainerView: View {
    @Binding var selectedTab: IOSAppTab

    var body: some View {
        IOSSettingsView(selectedTab: $selectedTab)
            .toolbar(.hidden, for: .navigationBar)
    }
}

private struct IOSSettingsView: View {
    @EnvironmentObject private var modelManager: ModelManagerViewModel
    @EnvironmentObject private var modelInstaller: IOSModelInstallerViewModel
    @Environment(\.openURL) private var openURL

    @Binding var selectedTab: IOSAppTab
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage(IOSGenerationVariationPreference.key) private var generationVariation = IOSGenerationVariationPreference.defaultValue
    @AppStorage(IOSAppDefaults.reduceMotionEnabledKey) private var reduceMotionEnabled = false
    @AppStorage(IOSAppDefaults.reduceTransparencyEnabledKey) private var reduceTransparencyEnabled = false
    // Drives the "Saved outputs" row value reactively (empty == internal "Keep in app (History)").
    @AppStorage(IOSSavedOutputsDestination.displayNameKey) private var savedOutputsName = ""
    @State private var isSavedOutputsDialogPresented = false
    @State private var isFolderPickerPresented = false

    private var previewSettingsState: IOSPreviewSettingsState? {
        IOSPreviewRuntime.current?.definition.settingsState
    }

    private var installedModelBytes: Int64 {
        TTSModel.all.reduce(0) { total, model in
            guard case let .installed(bytes) = effectiveStatus(for: model) else {
                return total
            }
            return total + Int64(bytes)
        }
    }

    private var storageSummaryText: String {
        installedModelBytes > 0
            ? "\(IOSSettingsFormatters.fileSize(installedModelBytes)) used"
            : "0 GB used"
    }

    var body: some View {
        IOSStudioShellScreen(
            selectedTab: $selectedTab,
            activeTab: .settings,
            tint: IOSAppTab.settings.dockAccent(studioMode: .custom)
        ) {
            IOSScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    IOSSettingsReferenceSection(title: "Voice models") {
                        ForEach(TTSModel.all) { model in
                            IOSModelRow(
                                model: model,
                                status: effectiveStatus(for: model),
                                operationState: effectiveOperationState(for: model),
                                onInstall: { install(model) },
                                onCancel: { cancel(model) },
                                onDelete: { delete(model) }
                            )

                            if model.id != TTSModel.all.last?.id {
                                IOSSettingsReferenceDivider()
                            }
                        }
                    }

                    IOSSettingsReferenceSection(title: "Settings") {
                        IOSSettingsReferenceToggleRow(
                            symbol: "play.fill",
                            title: "Autoplay after generate",
                            accessibilityIdentifier: "iosSettings_autoPlayToggle",
                            isOn: $autoPlay,
                            tint: IOSBrandTheme.accent
                        )

                        IOSSettingsReferenceDivider()

                        IOSSettingsVariationRow(selection: $generationVariation)

                        IOSSettingsReferenceDivider()

                        IOSSettingsReferenceValueRow(
                            symbol: "bookmark",
                            title: "Saved outputs",
                            accessibilityIdentifier: "iosSettings_savedOutputsRow",
                            value: savedOutputsName.isEmpty ? "Keep in app (History)" : savedOutputsName,
                            showsChevron: true,
                            action: { isSavedOutputsDialogPresented = true }
                        )

                        IOSSettingsReferenceDivider()

                        IOSSettingsReferenceValueRow(
                            symbol: "arrow.down.to.line",
                            title: "Storage",
                            accessibilityIdentifier: "iosSettings_storageRow",
                            value: storageSummaryText,
                            showsChevron: false
                        )

                        IOSSettingsReferenceDivider()

                        IOSSettingsReferenceToggleRow(
                            symbol: "sparkles",
                            title: "Reduce Motion",
                            accessibilityIdentifier: "iosSettings_reduceMotionToggle",
                            isOn: $reduceMotionEnabled,
                            tint: IOSBrandTheme.accent
                        )

                        IOSSettingsReferenceDivider()

                        IOSSettingsReferenceToggleRow(
                            symbol: "lock.fill",
                            title: "Reduce Transparency",
                            accessibilityIdentifier: "iosSettings_reduceTransparencyToggle",
                            isOn: $reduceTransparencyEnabled,
                            tint: IOSBrandTheme.accent
                        )
                    }

                    IOSSettingsReferenceSection(title: "About") {
                        IOSSettingsReferenceValueRow(
                            symbol: "hand.raised.fill",
                            title: "Privacy Policy",
                            accessibilityIdentifier: "iosSettings_privacyPolicyRow",
                            value: "",
                            showsChevron: true,
                            action: { open("https://vocello.vercel.app/privacy") }
                        )

                        IOSSettingsReferenceDivider()

                        IOSSettingsReferenceValueRow(
                            symbol: "chevron.left.forwardslash.chevron.right",
                            title: "Open source & licenses",
                            accessibilityIdentifier: "iosSettings_openSourceRow",
                            value: "",
                            showsChevron: true,
                            action: { open("https://github.com/PowerBeef/QwenVoice") }
                        )

                        IOSSettingsReferenceDivider()

                        // Permission recovery: mic / speech access is requested in-flow;
                        // if denied, this is the path back without leaving the app guessing.
                        IOSSettingsReferenceValueRow(
                            symbol: "gearshape.fill",
                            title: "Open iOS Settings",
                            accessibilityIdentifier: "iosSettings_openIOSSettingsRow",
                            value: "Permissions",
                            showsChevron: true,
                            action: { open(UIApplication.openSettingsURLString) }
                        )
                    }

                    IOSSettingsBrandFooter()
                }
                // Extra bottom padding so the bottom-most section clears
                // the TabDock's gradient fade in RootView.
                .padding(.bottom, 90)
            }
        }
        .task {
            await modelManager.refresh()
        }
        .confirmationDialog(
            "Saved outputs",
            isPresented: $isSavedOutputsDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Keep in app (History)") { IOSSavedOutputsDestination.clearFolder() }
            Button("Choose a Folder…") { isFolderPickerPresented = true }
        } message: {
            Text("Generated clips are always kept on this iPhone for History. Optionally also copy each new clip to a folder you choose — Files or iCloud Drive.")
        }
        .fileImporter(
            isPresented: $isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            try? IOSSavedOutputsDestination.setFolder(url)
        }
    }

    private func effectiveOperationState(for model: TTSModel) -> IOSModelInstallerViewModel.OperationState {
        if let previewState = previewSettingsState?.sample(for: model)?.operationState {
            return previewState
        }

        return modelInstaller.state(for: model)
    }

    private func effectiveStatus(for model: TTSModel) -> ModelManagerViewModel.ModelStatus {
        previewSettingsState?.sample(for: model)?.status
            ?? modelManager.statuses[model.id]
            ?? .checking
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        openURL(url)
    }

    private func install(_ model: TTSModel) {
        modelInstaller.install(model)
    }

    private func cancel(_ model: TTSModel) {
        modelInstaller.cancel(model)
    }

    private func delete(_ model: TTSModel) {
        modelInstaller.delete(model)
    }
}

private struct IOSSettingsReferenceSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .iosScaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .tracking(0.88)
                .foregroundStyle(IOSAppTheme.textSecondary)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }
}

private struct IOSSettingsUtilityIcon: View {
    let symbol: String

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
            }
            .frame(width: 36, height: 36)
    }
}

private struct IOSSettingsReferenceDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 64)
    }
}

private struct IOSSettingsReferenceSwitch: View {
    let isOn: Bool
    let tint: Color

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay {
                if isOn {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint,
                                    tint.mix(with: .black, by: 0.18, in: .perceptual),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(isOn ? tint.opacity(0.60) : Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .overlay {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.98, green: 0.97, blue: 0.94),
                                Color(red: 0.86, green: 0.84, blue: 0.79),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(isOn ? 0.22 : 0.18), radius: 2, x: 0, y: 1)
                    .frame(width: 21, height: 21)
                    .frame(maxWidth: .infinity, alignment: isOn ? .trailing : .leading)
                    .padding(2)
            }
            .shadow(color: isOn ? tint.opacity(0.18) : .clear, radius: 8, x: 0, y: 2)
            .frame(width: 44, height: 26)
    }
}

private struct IOSSettingsReferenceToggleRow: View {
    let symbol: String
    let title: String
    let accessibilityIdentifier: String
    @Binding var isOn: Bool
    let tint: Color

    var body: some View {
        Button {
            isOn.toggle()
            IOSHaptics.selection()
        } label: {
            HStack(spacing: 12) {
                IOSSettingsUtilityIcon(symbol: symbol)

                Text(title)
                    .iosScaledFont(size: 16)
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                IOSSettingsReferenceSwitch(isOn: isOn, tint: tint)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct IOSSettingsReferenceValueRow: View {
    let symbol: String
    let title: String
    let accessibilityIdentifier: String
    let value: String
    let showsChevron: Bool
    /// When set, the whole row becomes tappable (e.g. the "Saved outputs" destination picker).
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            IOSSettingsUtilityIcon(symbol: symbol)

            Text(title)
                .iosScaledFont(size: 16)
                .foregroundStyle(IOSAppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .iosScaledFont(size: 14)
                .foregroundStyle(IOSAppTheme.textSecondary)
                .lineLimit(1)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textTertiary)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Variation control (GitHub #47) — Expressive / Balanced / Consistent. A Menu
/// styled to match the reference value rows. Persisted via @AppStorage on the
/// shared IOSGenerationVariationPreference key; stamped onto every generation.
private struct IOSSettingsVariationRow: View {
    @Binding var selection: String

    private var currentDisplayName: String {
        (Qwen3SamplingVariation(rawValue: selection) ?? .expressive).displayName
    }

    var body: some View {
        Menu {
            ForEach(Qwen3SamplingVariation.allCases, id: \.self) { variation in
                Button {
                    selection = variation.rawValue
                    IOSHaptics.selection()
                } label: {
                    if selection == variation.rawValue {
                        Label(variation.displayName, systemImage: "checkmark")
                    } else {
                        Text(variation.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                IOSSettingsUtilityIcon(symbol: "dial.medium")

                Text("Variation")
                    .iosScaledFont(size: 16)
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(currentDisplayName)
                    .iosScaledFont(size: 14)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textTertiary)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("iosSettings_variationRow")
        .accessibilityLabel("Variation")
        .accessibilityValue(currentDisplayName)
        .accessibilityHint("How much takes vary when you regenerate the same text")
    }
}

private struct IOSSettingsBrandFooter: View {
    var body: some View {
        VStack(spacing: 2) {
            Image("VocelloLaunchLogo")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: 180)
                .shadow(color: IOSBrandTheme.accent.opacity(0.18), radius: 14, x: 0, y: 10)
                .accessibilityHidden(true)

            Text(Theme.Branding.version.uppercased())
                .font(.system(size: 11, weight: .medium))
                .accessibilityIdentifier("iosSettings_versionLabel")
                .tracking(0.66)
                .foregroundStyle(IOSAppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .opacity(0.78)
    }
}

private struct IOSSettingsLinkRow: View {
    let title: String
    let subtitle: String
    let urlString: String
    let accessibilityIdentifier: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = URL(string: urlString) else { return }
            openURL(url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct IOSSettingsSystemPreferencesRow: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open iOS Settings")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Adjust permissions and system preferences for Vocello.")
                        .font(.footnote)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("iosSettingsOpenSystemSettings")
    }
}

private struct IOSSettingsPlaybackRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-play generated audio")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Play each finished take automatically.")
                    .font(.footnote)
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(IOSBrandTheme.settings)
        .padding(.vertical, 2)
    }
}

private struct IOSSettingsProminentActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)

        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background { shape.fill(Color.clear) }
            .overlay {
                shape
                    .stroke(tint.opacity(configuration.isPressed ? 0.62 : 0.48), lineWidth: 0.5)
            }
            .opacity(configuration.isPressed ? 0.96 : 1.0)
            .iosAppAnimation(IOSSelectionMotion.press, value: configuration.isPressed)
    }
}

private extension View {
    func iosSettingsProminentActionButtonStyle(tint: Color) -> some View {
        buttonStyle(IOSSettingsProminentActionButtonStyle(tint: tint))
    }
}

private struct IOSModelRow: View {
    @Environment(AppModel.self) private var appModel

    let model: TTSModel
    let status: ModelManagerViewModel.ModelStatus
    let operationState: IOSModelInstallerViewModel.OperationState
    let onInstall: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isPresentingInstallSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                header
                Spacer(minLength: 12)
                controls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showsStatusDetail {
                statusDetailView
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("iosModelRow_\(model.id)")
        // Model rows route Download through IOSModelInstallSheet and Delete
        // through RootView's edge-to-edge IOSDeleteModelSheet overlay rather
        // than the old bare utility button + system confirmationDialog.
        // Auto-dismiss the install sheet once the operation lands
        // either at `.installed` or back at `.idle` after a cancel.
        .onChange(of: operationState) { _, newValue in
            guard isPresentingInstallSheet else { return }
            switch newValue {
            case .installed, .idle, .failed, .unavailable:
                isPresentingInstallSheet = false
                appModel.dismissBottomPanel()
                clearFocusBackdrop()
            default:
                presentInstallPanel()
            }
        }
        .onDisappear {
            if isPresentingInstallSheet {
                appModel.dismissBottomPanel()
                clearFocusBackdrop()
            }
        }
    }

    private func requestInstall() {
        presentFocusBackdrop()
        isPresentingInstallSheet = true
        presentInstallPanel()
    }

    private func requestDelete() {
        presentFocusBackdrop()
        appModel.deleteModelSheetItem = IOSDeleteModelSheetPresentation(
            modelName: model.name,
            sizeLabel: deleteSheetSizeLabel,
            onConfirm: {
                onDelete()
            }
        )
    }

    private func presentFocusBackdrop() {
        appModel.isFocusBackdropPresented = true
    }

    private func clearFocusBackdrop() {
        appModel.isFocusBackdropPresented = false
    }

    private func presentInstallPanel() {
        appModel.presentBottomPanel(id: "install-\(model.id)") { bottomSafeAreaInset, _, dismiss in
            AnyView(
                IOSModelInstallSheet(
                    item: installSheetItem,
                    isInstalling: installSheetIsInstalling,
                    progress: installSheetProgress,
                    onInstall: {
                        IOSHaptics.selection()
                        onInstall()
                    },
                    onCancel: {
                        onCancel()
                        isPresentingInstallSheet = false
                        dismiss()
                    },
                    onDismiss: dismiss,
                    presentation: .edgeToEdge(
                        bottomSafeAreaInset: bottomSafeAreaInset,
                        height: IOSBottomSheetChrome.modelInstallHeight
                    )
                )
            )
        }
    }

    // MARK: - Install sheet plumbing

    private var installSheetItem: IOSModelInstallSheetItem {
        IOSModelInstallSheetItem(
            id: model.id,
            name: model.name,
            symbol: "bolt.fill",
            sizeLabel: estimatedDownloadSizeLabel,
            description: installSheetDescription(for: model.mode),
            tint: IOSBrandTheme.modeColor(for: model.mode)
        )
    }

    /// Per-mode description that mirrors `design_references/Vocello iOS/
    /// data.js` `models[].desc`. Hand-wired here to avoid a model-layer
    /// change.
    private func installSheetDescription(for mode: GenerationMode) -> String {
        switch mode {
        case .custom:
            return model.supportsInstructionControl
                ? "Built-in speaker presets with controllable emotion and delivery."
                : "Smaller built-in speaker package optimized for iPhone memory."
        case .design: return "Describe a voice in natural language and Vocello renders it."
        case .clone:  return "Speak your text in a saved voice or any 10-20 s reference clip."
        }
    }

    private var estimatedDownloadSizeLabel: String {
        if let estimated = model.estimatedDownloadBytes {
            return IOSSettingsFormatters.fileSize(estimated)
        }
        if case let .installed(sizeBytes) = status {
            return IOSSettingsFormatters.fileSize(Int64(sizeBytes))
        }
        return "—"
    }

    private var deleteSheetSizeLabel: String {
        if case let .installed(sizeBytes) = status {
            return IOSSettingsFormatters.fileSize(Int64(sizeBytes))
        }
        if let estimated = model.estimatedDownloadBytes {
            return IOSSettingsFormatters.fileSize(estimated)
        }
        return "several GB"
    }

    private var installSheetIsInstalling: Binding<Bool> {
        Binding(
            get: {
                switch operationState {
                case .downloading, .resuming, .restarting, .verifying, .installing:
                    return true
                default:
                    return false
                }
            },
            set: { _ in }   // host-driven; the sheet doesn't toggle this
        )
    }

    private var installSheetProgress: Binding<Double> {
        Binding(
            get: {
                switch operationState {
                case .downloading(let progress, _, _),
                     .resuming(let progress, _, _),
                     .restarting(let progress, _, _):
                    return progress ?? 0
                case .verifying, .installing:
                    return 1.0
                default:
                    return 0
                }
            },
            set: { _ in }
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(IOSBrandTheme.modeColor(for: model.mode).opacity(0.16))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(IOSBrandTheme.modeColor(for: model.mode).opacity(0.38), lineWidth: 0.5)
                Image(systemName: modelIconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(IOSBrandTheme.modeColor(for: model.mode))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.mode.displayName)
                    .iosScaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .tracking(-0.075)
                    .foregroundStyle(IOSAppTheme.textPrimary)

                modelSubtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelSubtitle: some View {
        HStack(spacing: 6) {
            Text(variantDisplayText)

            if let estimatedSizeText {
                Text("·")
                Text(estimatedSizeText)
                    .monospacedDigit()
            }

            if let statusSummaryText {
                Text("·")
                Text(statusSummaryText)
                    .fontWeight(statusSummaryText == "Active" ? .semibold : .regular)
                    .foregroundStyle(statusSummaryText == "Active"
                                     ? IOSBrandTheme.modeColor(for: model.mode)
                                     : IOSAppTheme.textSecondary)
            }
        }
        .iosScaledFont(size: 12, relativeTo: .caption)
        .foregroundStyle(IOSAppTheme.textSecondary)
        .lineLimit(1)
    }

    // Match the Studio per-mode voice-selector chip glyphs (IOSGenerationModeViews) so the download
    // list reads the same as the mode UI — more representative than the old generic mic/wand glyphs.
    private var modelIconName: String {
        switch model.mode {
        case .custom: return "person.wave.2.fill"   // Custom "Voice" chip
        case .design: return "text.bubble.fill"     // Design "Voice brief" chip
        case .clone: return "waveform"              // Clone "Reference" chip (unchanged)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch operationState {
        case .idle:
            switch status {
            case .installed:
                installedControls
            case .checking:
                ProgressView()
            case .notInstalled:
                installButton(title: "Install", accessibilityIdentifier: "iosModelDownload_\(model.id)")
            case .incomplete, .error:
                installButton(title: "Repair", action: onInstall, accessibilityIdentifier: "iosModelRepair_\(model.id)")
            }
        case .installed:
            installedControls
        case .available:
            installButton(title: "Install", accessibilityIdentifier: "iosModelDownload_\(model.id)")
        case .downloading, .interrupted, .resuming, .restarting:
            installButton(title: "Cancel", action: onCancel, accessibilityIdentifier: "iosModelCancel_\(model.id)")
        case .verifying, .installing, .deleting:
            ProgressView()
        case .unavailable:
            if case .incomplete = status {
                installedControls
            }
        case .failed:
            installButton(title: "Retry", action: onInstall, accessibilityIdentifier: "iosModelRetry_\(model.id)")
        }
    }

    private var installedControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))

            Button(role: .destructive, action: requestDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle()
                            .fill(Color.white.opacity(0.04))
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("iosModelDelete_\(model.id)")
        }
    }

    private func installButton(
        title: String,
        action: (() -> Void)? = nil,
        accessibilityIdentifier: String
    ) -> some View {
        Button(title, action: action ?? requestInstall)
            .iosSettingsProminentActionButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var statusDetailView: some View {
        switch operationState {
        case .downloading(let progress, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress ?? 0)
                    .tint(IOSBrandTheme.modeColor(for: model.mode))
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.system(size: 12))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .interrupted(let message, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                Text(message ?? "Download interrupted.")
                    .font(.system(size: 12))
                    .foregroundStyle(IOSAppTheme.textSecondary)
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.system(size: 12))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .resuming(let progress, let downloadedBytes, let totalBytes),
                .restarting(let progress, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress ?? 0)
                    .tint(IOSBrandTheme.modeColor(for: model.mode))
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.system(size: 12))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .available, .verifying, .installing, .installed, .deleting, .unavailable, .idle:
            EmptyView()
        }
    }

    private var variantDisplayText: String {
        var parts: [String] = []
        switch model.qwen3Capabilities?.modelSize {
        case .compact0b6:
            parts.append("0.6B")
        case .pro1b7:
            parts.append("1.7B")
        case nil:
            break
        }
        if model.folder.localizedCaseInsensitiveContains("4bit") {
            parts.append("4-bit")
        } else if model.folder.localizedCaseInsensitiveContains("8bit") {
            parts.append("8-bit")
        }
        if model.mode == .custom, model.supportsInstructionControl == false {
            parts.append("speaker only")
        }
        if model.mode == .clone, model.supportsVoiceClone {
            parts.append("clone")
        }
        return parts.isEmpty ? "On-device" : parts.joined(separator: " · ")
    }

    private var estimatedSizeText: String? {
        let label = estimatedDownloadSizeLabel
        return label == "—" ? nil : label
    }

    private var showsStatusDetail: Bool {
        switch operationState {
        case .downloading, .interrupted, .resuming, .restarting:
            return true
        case .failed:
            return true
        default:
            return false
        }
    }

    private var statusSummaryText: String? {
        switch operationState {
        case .idle:
            switch status {
            case .checking:
                return "Checking…"
            case .notInstalled:
                return nil
            case .installed:
                return "Active"
            case .incomplete:
                return "Repair needed"
            case .error:
                return "Retry needed"
            }
        case .installed:
            return "Active"
        case .available:
            return nil
        case .downloading:
            return "Downloading…"
        case .interrupted:
            return "Interrupted"
        case .resuming:
            return "Resuming…"
        case .restarting:
            return "Restarting…"
        case .verifying:
            return "Verifying…"
        case .installing:
            return "Installing…"
        case .deleting:
            return "Removing…"
        case .unavailable:
            return "Unavailable"
        case .failed:
            return "Retry needed"
        }
    }

    private func progressText(downloadedBytes: Int64, totalBytes: Int64?) -> String {
        let current = IOSSettingsFormatters.fileSize(downloadedBytes)
        guard let totalBytes else { return "\(current) downloaded" }
        let total = IOSSettingsFormatters.fileSize(totalBytes)
        return "\(current) / \(total)"
    }
}
