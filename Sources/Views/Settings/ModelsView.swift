import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var viewModel: ModelManagerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Models")
                    .font(.title2.bold())
                    .foregroundStyle(AppTheme.models)
                    .accessibilityIdentifier("models_title")

                if viewModel.hasRefreshed {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(TTSModel.all) { model in
                            ModelCard(model: model, viewModel: viewModel)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                }
            }
            .padding(24)
            .contentColumn()
        }
        .task {
            await viewModel.refresh()
        }
    }
}

struct ModelCard: View {
    let model: TTSModel
    @ObservedObject var viewModel: ModelManagerViewModel

    private var status: ModelManagerViewModel.ModelStatus {
        viewModel.statuses[model.id] ?? .notDownloaded
    }

    private var modeColor: Color {
        AppTheme.modeColor(for: model.mode)
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: model.mode.iconName)
                .font(.title2)
                .foregroundColor(modeColor)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.body.bold())
                Text(model.folder)
                    .font(.caption)
                    .foregroundColor(.secondary)

                switch status {
                case .notDownloaded:
                    Text("Not downloaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .downloading(let progress):
                    let downloaded = Int64(progress * Double(model.estimatedSizeBytes))
                    let total = Int64(model.estimatedSizeBytes)
                    let formattedDL = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
                    let formattedTotal = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    VStack(alignment: .leading, spacing: 2) {
                        if progress <= 0 {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: 200, alignment: .leading)
                        } else {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(modeColor.opacity(0.18))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(modeColor)
                                        .frame(width: max(6, geo.size.width * min(progress, 1.0)))
                                }
                            }
                            .frame(maxWidth: 200, maxHeight: 6)
                        }
                        Text(progress >= 1.0 ? "Finalizing…" : progress <= 0 ? "Preparing download…" : "\(formattedDL) / \(formattedTotal)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                case .downloaded(let sizeBytes):
                    Text("Ready — \(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))")
                        .font(.caption)
                        .foregroundColor(modeColor)
                case .error:
                    Text("Download failed")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Spacer()

            switch status {
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
                    viewModel.delete(model)
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(modeColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(modeColor.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models_card_\(model.id)")
    }
}
