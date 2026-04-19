import SwiftUI
import QwenVoiceCore

struct IOSLibraryContainerView: View {
    @Binding var selectedTab: IOSAppTab
    @Binding var selectedSection: IOSLibrarySection
    let onUseVoiceInClone: (Voice) -> Void

    var body: some View {
        IOSStudioShellScreen(
            selectedTab: $selectedTab,
            activeTab: .library,
            tint: IOSBrandTheme.library
        ) {
            VStack(alignment: .leading, spacing: 14) {
                IOSStudioWorkspaceHeading(title: "Library")

                IOSLibrarySelectorCard(selectedSection: $selectedSection)

                Group {
                    switch selectedSection {
                    case .history:
                        IOSHistoryLibrarySection()
                    case .voices:
                        IOSSavedVoicesLibrarySection(onUseInVoiceCloning: onUseVoiceInClone)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct IOSLibrarySelectorCard: View {
    @Binding var selectedSection: IOSLibrarySection

    var body: some View {
        IOSCapsuleSelector(
            items: IOSLibrarySection.allCases,
            selection: $selectedSection,
            title: \.title,
            selectedTint: \.selectionTint,
            controlAccessibilityIdentifier: "librarySectionPicker",
            itemAccessibilityIdentifier: { "librarySection_\($0.rawValue)" }
        )
    }
}

private struct IOSHistoryFilterChips: View {
    @Binding var selection: IOSHistoryModeFilter

    var body: some View {
        IOSCapsuleSelector(
            items: IOSHistoryModeFilter.allCases,
            selection: $selection,
            title: \.title,
            selectedTint: \.tint,
            controlAccessibilityIdentifier: "historyModeFilter",
            itemAccessibilityIdentifier: { "historyModeFilter_\($0.rawValue)" }
        )
    }
}

enum IOSHistoryModeFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case custom
    case design
    case clone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .custom: return "Custom"
        case .design: return "Design"
        case .clone: return "Clone"
        }
    }

    var tint: Color {
        switch self {
        case .all: return IOSBrandTheme.library
        case .custom: return IOSBrandTheme.custom
        case .design: return IOSBrandTheme.design
        case .clone: return IOSBrandTheme.clone
        }
    }

    func matches(_ item: Generation) -> Bool {
        switch self {
        case .all: return true
        case .custom: return item.mode.lowercased() == "custom"
        case .design: return item.mode.lowercased() == "design"
        case .clone: return item.mode.lowercased() == "clone"
        }
    }
}

private enum IOSHistoryBucket: Int, CaseIterable, Identifiable {
    case today
    case yesterday
    case previous7
    case previous30
    case earlier

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7: return "Previous 7 Days"
        case .previous30: return "Previous 30 Days"
        case .earlier: return "Earlier"
        }
    }

    static func bucket(for date: Date, reference: Date = Date(), calendar: Calendar = .current) -> IOSHistoryBucket {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        guard let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: reference)).day else {
            return .earlier
        }
        if days <= 7 { return .previous7 }
        if days <= 30 { return .previous30 }
        return .earlier
    }
}

private struct IOSHistoryLibrarySection: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel

    @State private var items: [Generation] = []
    @State private var errorMessage: String?
    @State private var modeFilter: IOSHistoryModeFilter = .all
    @State private var searchQuery: String = ""
    @State private var debouncedQuery: String = ""

    private var filteredItems: [Generation] {
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard modeFilter.matches(item) else { return false }
            guard !trimmed.isEmpty else { return true }
            if item.text.localizedCaseInsensitiveContains(trimmed) { return true }
            if let voice = item.voice, voice.localizedCaseInsensitiveContains(trimmed) { return true }
            if item.mode.localizedCaseInsensitiveContains(trimmed) { return true }
            return false
        }
    }

    private var groupedItems: [(bucket: IOSHistoryBucket, items: [Generation])] {
        let reference = Date()
        let calendar = Calendar.current
        var map: [IOSHistoryBucket: [Generation]] = [:]
        for item in filteredItems {
            let bucket = IOSHistoryBucket.bucket(for: item.createdAt, reference: reference, calendar: calendar)
            map[bucket, default: []].append(item)
        }
        return IOSHistoryBucket.allCases.compactMap { bucket in
            guard let rows = map[bucket], !rows.isEmpty else { return nil }
            return (bucket, rows)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IOSHistoryFilterChips(selection: $modeFilter)

            TextField("Search history", text: $searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .iosFieldChrome(tint: IOSBrandTheme.library)
                .accessibilityIdentifier("historySearchField")

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if errorMessage != nil, items.isEmpty {
                        IOSEmptyStateCard(
                            title: "Couldn't load history",
                            message: "Something went wrong reading your history. Pull to retry.",
                            symbolName: "exclamationmark.triangle",
                            tint: .orange
                        )
                        Button("Retry", action: reload)
                            .iosAdaptiveUtilityButtonStyle(tint: IOSBrandTheme.library)
                            .accessibilityIdentifier("historyRetryButton")
                    } else if items.isEmpty {
                        IOSEmptyStateCard(
                            title: "No takes yet",
                            message: "Generated audio shows up here once you create a voice or line.",
                            symbolName: "clock.arrow.circlepath",
                            tint: IOSBrandTheme.library
                        )
                    } else if filteredItems.isEmpty {
                        IOSEmptyStateCard(
                            title: "No matches",
                            message: "Nothing matches this filter or search. Try widening it.",
                            symbolName: "line.3.horizontal.decrease.circle",
                            tint: IOSBrandTheme.library
                        )
                    } else {
                        ForEach(groupedItems, id: \.bucket.id) { group in
                            IOSSectionHeading(group.bucket.title)
                            ForEach(group.items) { item in
                                IOSHistoryItemCard(
                                    item: item,
                                    onPlay: {
                                        audioPlayer.playFile(
                                            item.audioPath,
                                            title: item.textPreview,
                                            presentationContext: .library
                                        )
                                    },
                                    onDelete: { delete(item) }
                                )
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("historyRow_\(item.historyAccessibilityID)")
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .generationSaved)) { _ in
            reload()
        }
        .task(id: searchQuery) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            debouncedQuery = searchQuery
        }
    }

    private func reload() {
        do {
            items = try DatabaseService.shared.fetchAllGenerations()
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ item: Generation) {
        do {
            if let id = item.id {
                try DatabaseService.shared.deleteGeneration(id: id)
            }
            if FileManager.default.fileExists(atPath: item.audioPath) {
                try? FileManager.default.removeItem(atPath: item.audioPath)
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct IOSHistoryItemCard: View {
    let item: Generation
    let onPlay: () -> Void
    let onDelete: () -> Void

    private var modeText: String {
        switch item.mode.lowercased() {
        case "custom":
            return "Custom"
        case "design":
            return "Design"
        case "clone":
            return "Clone"
        default:
            return item.mode.capitalized
        }
    }

    private var modeTint: Color {
        switch item.mode.lowercased() {
        case "custom":
            return IOSBrandTheme.custom
        case "design":
            return IOSBrandTheme.design
        case "clone":
            return IOSBrandTheme.clone
        default:
            return IOSBrandTheme.library
        }
    }

    private var durationText: String? {
        guard let duration = item.duration else { return nil }
        return String(format: "%.1fs", duration)
    }

    var body: some View {
        IOSSurfaceCard(tint: modeTint) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(IOSAppTheme.accentSurface(modeTint))
                        .frame(width: 44, height: 44)
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(modeTint)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.textPreview)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(historyMetadata)
                        .font(.caption)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                    }
                    .iosAdaptiveUtilityButtonStyle(prominent: true, tint: modeTint)

                    Menu {
                        if FileManager.default.fileExists(atPath: item.audioPath) {
                            ShareLink(item: URL(fileURLWithPath: item.audioPath)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .iosAdaptiveUtilityButtonStyle(tint: IOSBrandTheme.library)
                }
            }
        }
    }

    private var historyMetadata: String {
        let parts = [modeText, durationText, item.formattedDate].compactMap { $0 }
        return parts.joined(separator: " • ")
    }
}

private struct IOSSavedVoicesLibrarySection: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var audioPlayer: AudioPlayerViewModel
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel

    let onUseInVoiceCloning: (Voice) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !ttsEngine.isReady {
                    IOSEmptyStateCard(
                        title: "Preparing runtime",
                        message: "Saved voices will appear as soon as the runtime is ready.",
                        symbolName: "hourglass",
                        tint: IOSBrandTheme.library
                    )
                } else if savedVoicesViewModel.isLoading && savedVoicesViewModel.voices.isEmpty {
                    IOSStudioSectionGroup(tint: IOSBrandTheme.library) {
                        HStack {
                            Spacer()
                            ProgressView("Loading saved voices…")
                            Spacer()
                        }
                    }
                } else if let loadError = savedVoicesViewModel.loadError, savedVoicesViewModel.voices.isEmpty {
                    IOSEmptyStateCard(
                        title: "Saved voices unavailable",
                        message: loadError,
                        symbolName: "exclamationmark.triangle",
                        tint: .orange
                    )
                } else if savedVoicesViewModel.voices.isEmpty {
                    IOSEmptyStateCard(
                        title: "No saved voices yet",
                        message: "Saved voice designs show up here after you choose to keep one.",
                        symbolName: "person.wave.2",
                        tint: IOSBrandTheme.library
                    )
                } else {
                    ForEach(savedVoicesViewModel.voices) { voice in
                        IOSSavedVoiceCard(
                            voice: voice,
                            onPlay: {
                                audioPlayer.playFile(
                                    voice.wavPath,
                                    title: voice.name,
                                    presentationContext: .library
                                )
                            },
                            onUseInVoiceCloning: {
                                onUseInVoiceCloning(voice)
                            },
                            onDelete: {
                                Task {
                                    do {
                                        try await ttsEngine.deletePreparedVoice(id: voice.id)
                                        await MainActor.run {
                                            savedVoicesViewModel.removeVoiceFromVisibleState(id: voice.id)
                                        }
                                        await savedVoicesViewModel.refresh(using: ttsEngine)
                                    } catch {
                                        #if DEBUG
                                        print("[IOSSavedVoicesLibrarySection] delete failed: \(error.localizedDescription)")
                                        #endif
                                    }
                                }
                            }
                        )
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .task {
            guard ttsEngine.isReady else { return }
            await savedVoicesViewModel.refresh(using: ttsEngine)
        }
    }
}

private struct IOSSavedVoiceCard: View {
    let voice: Voice
    let onPlay: () -> Void
    let onUseInVoiceCloning: () -> Void
    let onDelete: () -> Void

    var body: some View {
        IOSSurfaceCard(tint: IOSBrandTheme.library) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(IOSAppTheme.accentSurface(IOSBrandTheme.library))
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.wave.2.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(IOSBrandTheme.library)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(voice.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)

                    Text(voiceMetadata)
                        .font(.caption)
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                    }
                    .iosAdaptiveUtilityButtonStyle(prominent: true, tint: IOSBrandTheme.library)

                    Menu {
                        Button("Use in Clone", action: onUseInVoiceCloning)
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .iosAdaptiveUtilityButtonStyle(tint: IOSBrandTheme.library)
                }
            }
        }
    }

    private var voiceMetadata: String {
        voice.hasTranscript ? "Saved voice • Transcript ready" : "Saved voice"
    }
}
