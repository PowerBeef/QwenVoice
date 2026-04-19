import SwiftUI
import UIKit
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

    @Binding var selectedTab: IOSAppTab
    @AppStorage("autoPlay") private var autoPlay = true

    private var runtimeDescription: String {
        IOSSimulatorRuntimeSupport.isSimulator ? "Simulator" : "On-device"
    }

    private var previewSettingsState: IOSPreviewSettingsState? {
        IOSPreviewRuntime.current?.definition.settingsState
    }

    var body: some View {
        IOSStudioShellScreen(
            selectedTab: $selectedTab,
            activeTab: .settings,
            tint: IOSBrandTheme.settings
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    IOSStudioWorkspaceHeading(title: "Settings")

                    IOSStudioSectionGroup(title: "Playback", tint: IOSBrandTheme.settings) {
                        IOSSettingsPlaybackRow(isOn: $autoPlay)
                    }

                    IOSStudioSectionGroup(title: "Model Assets", tint: IOSBrandTheme.settings) {
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
                                Divider()
                                    .overlay(IOSAppTheme.hairlineDivider)
                            }
                        }
                    }

                    IOSStudioSectionGroup(title: "Runtime", tint: IOSBrandTheme.settings) {
                        IOSHeaderMetricRow(label: "Runtime", value: runtimeDescription)

                        Divider()
                            .overlay(IOSAppTheme.hairlineDivider)

                        IOSHeaderMetricRow(
                            label: "Minimum supported hardware",
                            value: "iPhone 15 Pro or newer"
                        )
                    }

                    IOSStudioSectionGroup(title: "Support", tint: IOSBrandTheme.settings) {
                        IOSHeaderMetricRow(label: "App version", value: IOSSettingsSupportInfo.appVersionLabel)

                        Divider()
                            .overlay(IOSAppTheme.hairlineDivider)

                        IOSSettingsSystemPreferencesRow()
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .task {
            await modelManager.refresh()
        }
    }

    private func effectiveOperationState(for model: TTSModel) -> IOSModelInstallerViewModel.OperationState {
        if let previewState = previewSettingsState?.sample(for: model)?.operationState {
            return previewState
        }

        return IOSSimulatorPreviewPolicy.previewOperationState(
            for: model,
            status: effectiveStatus(for: model),
            operationState: modelInstaller.state(for: model)
        )
    }

    private func effectiveStatus(for model: TTSModel) -> ModelManagerViewModel.ModelStatus {
        previewSettingsState?.sample(for: model)?.status
            ?? modelManager.statuses[model.id]
            ?? .checking
    }

    private func install(_ model: TTSModel) {
        guard IOSSimulatorPreviewPolicy.allowsModelMutations else { return }
        modelInstaller.install(model)
    }

    private func cancel(_ model: TTSModel) {
        guard IOSSimulatorPreviewPolicy.allowsModelMutations else { return }
        modelInstaller.cancel(model)
    }

    private func delete(_ model: TTSModel) {
        guard IOSSimulatorPreviewPolicy.allowsModelMutations else { return }
        modelInstaller.delete(model)
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
    @ScaledMetric(relativeTo: .footnote) private var horizontalPadding = 14
    @ScaledMetric(relativeTo: .footnote) private var verticalPadding = 6

    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)

        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.black.opacity(configuration.isPressed ? 0.72 : 0.78))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .iosSubtleGlassSurface(
                in: shape,
                tint: tint,
                fill: tint.opacity(configuration.isPressed ? 0.14 : 0.10),
                strokeOpacity: configuration.isPressed ? 0.30 : 0.22,
                interactive: true
            )
            .overlay {
                shape
                    .stroke(tint.opacity(configuration.isPressed ? 0.42 : 0.34), lineWidth: 0.9)
            }
            .opacity(configuration.isPressed ? 0.96 : 1.0)
            .animation(IOSSelectionMotion.press, value: configuration.isPressed)
    }
}

private extension View {
    func iosSettingsProminentActionButtonStyle(tint: Color) -> some View {
        buttonStyle(IOSSettingsProminentActionButtonStyle(tint: tint))
    }
}

private struct IOSModelRow: View {
    let model: TTSModel
    let status: ModelManagerViewModel.ModelStatus
    let operationState: IOSModelInstallerViewModel.OperationState
    let onInstall: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    header
                    Spacer(minLength: 12)
                    controlsRow
                }

                VStack(alignment: .leading, spacing: 8) {
                    header
                    controlsRow
                }
            }

            statusDetailView
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("iosModelRow_\(model.id)")
        .confirmationDialog(
            "Delete \(model.name)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                IOSHaptics.warning()
                onDelete()
            }
            .accessibilityIdentifier("iosModelDeleteConfirm_\(model.id)")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees several GB but requires a full re-download before you can use this model again.")
        }
    }

    private func requestDelete() {
        isConfirmingDelete = true
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(IOSAppTheme.textPrimary)
            Text(secondaryLineText)
                .font(.subheadline)
                .foregroundStyle(IOSAppTheme.textSecondary)
                .lineLimit(1)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            controls
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var controls: some View {
        switch operationState {
        case .idle:
            switch status {
            case .installed:
                Button("Delete", role: .destructive, action: requestDelete)
                    .controlSize(.small)
                    .iosAdaptiveUtilityButtonStyle(tint: .red)
                    .accessibilityIdentifier("iosModelDelete_\(model.id)")
            case .checking:
                ProgressView()
            case .notInstalled:
                EmptyView()
            case .incomplete, .error:
                Button("Repair", action: onInstall)
                    .iosSettingsProminentActionButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
                    .accessibilityIdentifier("iosModelRepair_\(model.id)")
            }
        case .installed:
            Button("Delete", role: .destructive, action: requestDelete)
                .controlSize(.small)
                .iosAdaptiveUtilityButtonStyle(tint: .red)
                .accessibilityIdentifier("iosModelDelete_\(model.id)")
        case .available:
            Button("Download", action: onInstall)
                .iosSettingsProminentActionButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
                .accessibilityIdentifier("iosModelDownload_\(model.id)")
        case .downloading:
            Button("Cancel", action: onCancel)
                .controlSize(.small)
                .iosAdaptiveUtilityButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
                .accessibilityIdentifier("iosModelCancel_\(model.id)")
        case .verifying, .installing, .deleting:
            ProgressView()
        case .unavailable:
            if case .incomplete = status {
                Button("Delete", role: .destructive, action: requestDelete)
                    .controlSize(.small)
                    .iosAdaptiveUtilityButtonStyle(tint: .red)
                    .accessibilityIdentifier("iosModelDelete_\(model.id)")
            }
        case .failed:
            Button("Retry", action: onInstall)
                .iosSettingsProminentActionButtonStyle(tint: IOSBrandTheme.modeColor(for: model.mode))
                .accessibilityIdentifier("iosModelRetry_\(model.id)")
        }
    }

    @ViewBuilder
    private var statusDetailView: some View {
        switch operationState {
        case .downloading(let progress, let downloadedBytes, let totalBytes):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress ?? 0)
                Text(progressText(downloadedBytes: downloadedBytes, totalBytes: totalBytes))
                    .font(.footnote)
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }
        case .failed(let message):
            if !IOSSimulatorPreviewPolicy.isSimulatorPreview {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .available, .verifying, .installing, .installed, .deleting, .unavailable, .idle:
            EmptyView()
        }
    }

    private var secondaryLineText: String {
        [model.mode.displayName, model.tier.uppercased(), statusSummaryText]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    private var statusSummaryText: String? {
        switch operationState {
        case .idle:
            switch status {
            case .checking:
                return "Checking…"
            case .notInstalled:
                return "Not installed"
            case .installed(let sizeBytes):
                return "Installed \(IOSSettingsFormatters.fileSize(Int64(sizeBytes)))"
            case .incomplete:
                return "Repair needed"
            case .error:
                return "Retry needed"
            }
        case .installed:
            return "Installed"
        case .available(let estimatedBytes):
            guard let estimatedBytes else { return "Download available" }
            return "Download \(IOSSettingsFormatters.fileSize(estimatedBytes))"
        case .downloading:
            return "Downloading…"
        case .verifying:
            return "Verifying…"
        case .installing:
            return "Installing…"
        case .deleting:
            return "Removing…"
        case .unavailable:
            return IOSSimulatorPreviewPolicy.isSimulatorPreview ? "Unavailable in Simulator" : "Unavailable"
        case .failed:
            return IOSSimulatorPreviewPolicy.isSimulatorPreview ? "Unavailable in Simulator" : "Retry needed"
        }
    }

    private func progressText(downloadedBytes: Int64, totalBytes: Int64?) -> String {
        let current = IOSSettingsFormatters.fileSize(downloadedBytes)
        guard let totalBytes else { return "\(current) downloaded" }
        let total = IOSSettingsFormatters.fileSize(totalBytes)
        return "\(current) / \(total)"
    }
}
