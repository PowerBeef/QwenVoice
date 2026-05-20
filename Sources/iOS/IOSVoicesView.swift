import SwiftUI
import QwenVoiceCore

/// Unified Voices tab from design_references/Vocello iOS/screens.jsx
/// (Voices section). Combines built-in speakers from the TTSContract with
/// saved (cloned) voices from SavedVoicesViewModel under one search +
/// filter chrome. Tapping a built-in speaker routes to Studio Custom mode
/// preselected; tapping a saved voice routes to Studio Clone mode with
/// the existing PendingVoiceCloningHandoff plumbing.
///
/// Wired in QVoiceiOSRootView's `.voices` case (Track D). Track I will add
/// the dashed "Save a new voice" header card with full preview play, and
/// hook the per-row Play button into a shared `AudioPlayerViewModel`-
/// driven preview path.
struct IOSVoicesView: View {
    @Binding var selectedTab: IOSAppTab
    let onSelectBuiltInSpeaker: (SpeakerDescriptor) -> Void
    let onSelectSavedVoice: (Voice) -> Void

    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel

    @State private var search: String = ""
    @State private var filter: VoiceFilter = .all

    private var builtIn: [SpeakerDescriptor] {
        TTSContract.allSpeakerDescriptors.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var saved: [Voice] {
        savedVoicesViewModel.voices.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var filteredBuiltIn: [SpeakerDescriptor] {
        guard filter != .saved else { return [] }
        return builtIn.filter(matchesSearch)
    }

    private var filteredSaved: [Voice] {
        guard filter != .builtIn else { return [] }
        return saved.filter(matchesSearch)
    }

    var body: some View {
        IOSStudioShellScreen(
            selectedTab: $selectedTab,
            activeTab: .voices,
            tint: IOSBrandTheme.library
        ) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    IOSSearchField(text: $search, placeholder: "Search voices")

                    IOSFilterChipRow(
                        options: VoiceFilter.allCases,
                        selection: $filter,
                        tint: IOSBrandTheme.library,
                        label: \.label
                    )
                    .padding(.horizontal, -16)

                    saveACallCard

                    if !filteredSaved.isEmpty {
                        Text("Saved voices")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(IOSAppTheme.textTertiary)

                        VStack(spacing: 8) {
                            ForEach(filteredSaved, id: \.id) { voice in
                                savedRow(voice)
                            }
                        }
                    }

                    if !filteredBuiltIn.isEmpty {
                        Text("Built-in")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(IOSAppTheme.textTertiary)
                            .padding(.top, 6)

                        VStack(spacing: 8) {
                            ForEach(filteredBuiltIn, id: \.id) { speaker in
                                builtInRow(speaker)
                            }
                        }
                    }

                    if filteredBuiltIn.isEmpty && filteredSaved.isEmpty {
                        IOSEmptyStateCard(
                            title: "Nothing matches",
                            message: "Try a different search term or switch the filter back to All.",
                            symbolName: "magnifyingglass",
                            tint: IOSBrandTheme.library
                        )
                        .padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .task {
                await savedVoicesViewModel.ensureLoaded(using: ttsEngine)
            }
        }
        .accessibilityIdentifier("screen_voices")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Voices")
                .font(.system(.title2, design: .default, weight: .semibold))
                .foregroundStyle(IOSAppTheme.textPrimary)
            Text("Built-in speakers and voices you saved from clone takes.")
                .font(.subheadline)
                .foregroundStyle(IOSAppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Save-a-voice CTA

    private var saveACallCard: some View {
        Button {
            IOSHaptics.selection()
            selectedTab = .studio
            // The actual draft-mode preset (clone) is set by the call-site
            // closure plumbed through QVoiceiOSRootView; here we just
            // surface the affordance.
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(IOSBrandTheme.clone.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(IOSBrandTheme.clone)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Save a new voice")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                    Text("Open Studio in Clone mode and capture a reference clip.")
                        .font(.caption)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .strokeBorder(IOSBrandTheme.clone.opacity(0.4), style: StrokeStyle(lineWidth: 0.9, dash: [4, 3]))
                    .background {
                        RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                            .fill(IOSAppTheme.accentWash(IOSBrandTheme.clone))
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voices_saveNewVoice")
    }

    // MARK: - Rows

    private func builtInRow(_ speaker: SpeakerDescriptor) -> some View {
        Button {
            IOSHaptics.selection()
            onSelectBuiltInSpeaker(speaker)
        } label: {
            HStack(spacing: 12) {
                IOSVoiceAvatar(
                    seed: speaker.id,
                    initials: speaker.displayName,
                    diameter: 42
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(speaker.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                    if let detail = builtInSubtitle(for: speaker) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(IOSAppTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voicesRow_\(speaker.id)")
    }

    private func savedRow(_ voice: Voice) -> some View {
        Button {
            IOSHaptics.selection()
            onSelectSavedVoice(voice)
        } label: {
            HStack(spacing: 12) {
                IOSVoiceAvatar(
                    seed: voice.id,
                    initials: voice.name,
                    diameter: 42
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                    Text("Cloned reference")
                        .font(.caption)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                }

                Spacer(minLength: 8)

                IOSStatusBadge(text: "Clone", tone: .accent(IOSBrandTheme.clone))

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: IOSCornerRadius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voicesRow_saved_\(voice.id)")
    }

    // MARK: - Helpers

    private func builtInSubtitle(for speaker: SpeakerDescriptor) -> String? {
        if let detail = speaker.shortDescription, !detail.isEmpty { return detail }
        if let lang = speaker.nativeLanguage, !lang.isEmpty {
            return speaker.isEnglishNative ? "\(lang) - English native" : lang
        }
        return speaker.group.capitalized
    }

    private func matchesSearch(_ speaker: SpeakerDescriptor) -> Bool {
        guard !search.isEmpty else { return true }
        let q = search.lowercased()
        if speaker.displayName.lowercased().contains(q) { return true }
        if (speaker.shortDescription ?? "").lowercased().contains(q) { return true }
        if (speaker.nativeLanguage ?? "").lowercased().contains(q) { return true }
        return false
    }

    private func matchesSearch(_ voice: Voice) -> Bool {
        guard !search.isEmpty else { return true }
        return voice.name.lowercased().contains(search.lowercased())
    }
}

// MARK: - Filter

private enum VoiceFilter: String, Identifiable, CaseIterable, Hashable {
    case all
    case builtIn
    case saved

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .builtIn: return "Built-in"
        case .saved: return "Saved"
        }
    }
}
