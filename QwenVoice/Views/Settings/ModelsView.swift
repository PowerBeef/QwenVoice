import SwiftUI

struct ModelsView: View {
    @StateObject private var viewModel = ModelManagerViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Models")
                    .font(.title2.bold())
                    .accessibilityIdentifier("models_title")

                // Pro models
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pro (1.7B) — Best Quality")
                        .font(.headline)
                        .accessibilityIdentifier("models_proSection")
                    ForEach(TTSModel.all.filter { $0.tier == .pro }) { model in
                        ModelCard(model: model, viewModel: viewModel)
                    }
                }

                Divider()

                // Lite models
                VStack(alignment: .leading, spacing: 12) {
                    Text("Lite (0.6B) — Faster")
                        .font(.headline)
                        .accessibilityIdentifier("models_liteSection")
                    ForEach(TTSModel.all.filter { $0.tier == .lite }) { model in
                        ModelCard(model: model, viewModel: viewModel)
                    }
                }
            }
            .padding(24)
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

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: model.mode.iconName)
                .font(.title2)
                .foregroundColor(.accentColor)
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
                    ProgressView(value: progress)
                        .frame(width: 200)
                case .downloaded(let sizeBytes):
                    Text("Ready — \(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            switch status {
            case .notDownloaded:
                Button("Download") {
                    Task { await viewModel.download(model) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("models_download_\(model.id)")
            case .downloading:
                Button("Cancel") {
                    viewModel.cancelDownload(model)
                }
                .controlSize(.small)
            case .downloaded:
                Button(role: .destructive) {
                    Task { await viewModel.delete(model) }
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .accessibilityIdentifier("models_delete_\(model.id)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models_card_\(model.id)")
    }
}
