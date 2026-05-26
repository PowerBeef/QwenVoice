import SwiftUI
import QwenVoiceCore

struct IOSLibraryContainerView: View {
    @Binding var selectedTab: IOSAppTab
    @Binding var selectedSection: IOSLibrarySection
    let onUseVoiceInClone: (Voice) -> Void

    /// When true, render the legacy "Library" heading + History/Voices
    /// section selector. The new 4-tab IA in `RootView` already routes
    /// History and Voices as their own top-level tabs, so the tab dock
    /// performs the section switch and the heading is redundant. The
    /// per-screen entry points (HistoryScreen, VoicesScreen) pass
    /// `showsHeader: false`. Existing internal call sites that still
    /// surface the unified Library section can leave it true.
    let showsHeader: Bool

    init(
        selectedTab: Binding<IOSAppTab>,
        selectedSection: Binding<IOSLibrarySection>,
        showsHeader: Bool = true,
        onUseVoiceInClone: @escaping (Voice) -> Void
    ) {
        self._selectedTab = selectedTab
        self._selectedSection = selectedSection
        self.showsHeader = showsHeader
        self.onUseVoiceInClone = onUseVoiceInClone
    }

    private var activeTab: IOSAppTab {
        switch selectedSection {
        case .voices: return .voices
        case .history: return .history
        }
    }

    var body: some View {
        IOSStudioShellScreen(
            selectedTab: $selectedTab,
            activeTab: activeTab,
            tint: activeTab.dockAccent(studioMode: .custom)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if showsHeader {
                    IOSStudioWorkspaceHeading(title: "Library")
                    IOSLibrarySelectorCard(selectedSection: $selectedSection)
                }

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
        IOSFilterChipRow(
            options: IOSHistoryModeFilter.allCases,
            selection: $selection,
            tint: IOSBrandTheme.library,
            label: \.title,
            leading: { filter in
                AnyView(IOSModeDot(tint: filter.dotColor, diameter: 7))
            },
            accessibilityIdentifier: { "historyModeFilter_\($0.rawValue)" }
        )
        .accessibilityIdentifier("historyModeFilter")
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

    var dotColor: Color {
        switch self {
        case .all: return Color.white.opacity(0.40)
        case .custom, .design, .clone: return tint
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
    @State private var items: [Generation] = []
    @State private var errorMessage: String?
    @State private var modeFilter: IOSHistoryModeFilter = .all
    @State private var searchQuery: String = ""
    @State private var debouncedQuery: String = ""
    @State private var groupedItems: [(bucket: IOSHistoryBucket, items: [Generation])] = []
    @State private var filteredItemCount = 0
    @State private var reloadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IOSSearchField(text: $searchQuery, placeholder: "Search transcript or voice")
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                .accessibilityIdentifier("historySearchField")

            IOSHistoryFilterChips(selection: $modeFilter)
                .padding(.bottom, 0)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if errorMessage != nil, items.isEmpty {
                        IOSEmptyStateCard(
                            title: "Couldn't load history",
                            message: "Something went wrong reading your history. Pull to retry.",
                            symbolName: "exclamationmark.triangle",
                            tint: .orange
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        Button("Retry", action: reload)
                            .iosAdaptiveUtilityButtonStyle(tint: IOSBrandTheme.library)
                            .padding(.horizontal, 20)
                            .accessibilityIdentifier("historyRetryButton")
                    } else if items.isEmpty {
                        IOSEmptyStateCard(
                            title: "No takes yet",
                            message: "Generated audio shows up here once you create a voice or line.",
                            symbolName: "clock.arrow.circlepath",
                            tint: IOSBrandTheme.library
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    } else if filteredItemCount == 0 {
                        IOSEmptyStateCard(
                            title: "No matches",
                            message: "Nothing matches this filter or search. Try widening it.",
                            symbolName: "line.3.horizontal.decrease.circle",
                            tint: IOSBrandTheme.library
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    } else {
                        ForEach(groupedItems, id: \.bucket.id) { group in
                            IOSSectionHeading(group.bucket.title)
                            ForEach(group.items) { item in
                                IOSHistoryItemCard(
                                    item: item,
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
        .onDisappear {
            reloadTask?.cancel()
            reloadTask = nil
        }
        .onChange(of: modeFilter) { _, _ in
            recomputePresentation()
        }
        .onChange(of: debouncedQuery) { _, _ in
            recomputePresentation()
        }
        .task(id: searchQuery) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            debouncedQuery = searchQuery
        }
    }

    private func reload() {
        reloadTask?.cancel()
        reloadTask = Task {
            do {
                let loadedItems = try await Task.detached(priority: .userInitiated) {
                    try DatabaseService.shared.fetchAllGenerations()
                }.value
                guard !Task.isCancelled else { return }
                items = loadedItems
                errorMessage = nil
                recomputePresentation()
            } catch {
                guard !Task.isCancelled else { return }
                items = []
                groupedItems = []
                filteredItemCount = 0
                errorMessage = error.localizedDescription
            }
            reloadTask = nil
        }
    }

    private func recomputePresentation() {
        let grouped = Self.makeGroupedItems(
            items: items,
            modeFilter: modeFilter,
            query: debouncedQuery
        )
        groupedItems = grouped
        filteredItemCount = grouped.reduce(0) { $0 + $1.items.count }
    }

    private static func makeGroupedItems(
        items: [Generation],
        modeFilter: IOSHistoryModeFilter,
        query: String
    ) -> [(bucket: IOSHistoryBucket, items: [Generation])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredItems = items.filter { item in
            guard modeFilter.matches(item) else { return false }
            guard !trimmed.isEmpty else { return true }
            if item.text.localizedCaseInsensitiveContains(trimmed) { return true }
            if let voice = item.voice, voice.localizedCaseInsensitiveContains(trimmed) { return true }
            if item.mode.localizedCaseInsensitiveContains(trimmed) { return true }
            return false
        }

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
    let onDelete: () -> Void

    @State private var isConfirmingDelete = false
    @Environment(\.presentIOSPlayerSheet) private var presentPlayerSheet

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

    private var thumbnailSeed: Int {
        // Deterministic waveform: same row renders the same bars across
        // launches. Use the database row id when present, fall back to a
        // stable hash of the audio path.
        if let id = item.id { return Int(truncatingIfNeeded: id) }
        return IOSStableVisualHash.int(item.audioPath)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: openPlayerSheet) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(modeTint.opacity(0.14))
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.02))
                            }
                            .frame(width: 48, height: 48)
                        IOSWaveformBars(
                            seed: thumbnailSeed,
                            barCount: 14,
                            tint: modeTint,
                            progress: 1.0,
                            isAnimating: false
                        )
                        .frame(width: 34, height: 22)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.textPreview)
                            .font(.system(size: 15, weight: .medium))
                            .tracking(-0.15)
                            .foregroundStyle(IOSAppTheme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 6) {
                            IOSModeDot(tint: modeTint)
                            if let voice = item.voice, !voice.isEmpty {
                                Text(voice)
                            } else {
                                Text(modeText)
                            }
                            Text("·")
                            Text(item.formattedDate)
                            if let durationText {
                                Text("·")
                                Text(durationText)
                                    .monospacedDigit()
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("historyRowTap_\(item.historyAccessibilityID)")

            Menu {
                Button {
                    openPlayerSheet()
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                if FileManager.default.fileExists(atPath: item.audioPath) {
                    ShareLink(item: URL(fileURLWithPath: item.audioPath)) {
                        Label("Save audio", systemImage: "square.and.arrow.down")
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    isConfirmingDelete = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background {
                        Circle().fill(Color.white.opacity(0.06))
                    }
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("historyRowMenu_\(item.historyAccessibilityID)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.leading, 76)
                .padding(.trailing, 20)
        }
        .confirmationDialog(
            "Delete this take?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                IOSHaptics.warning()
                onDelete()
            }
            .accessibilityIdentifier("historyRowDeleteConfirm_\(item.historyAccessibilityID)")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the generated audio and its history entry.")
        }
    }

    private func openPlayerSheet() {
        let playerItem = IOSPlayerSheetItem.from(history: item)
        IOSHaptics.selection()
        presentPlayerSheet(playerItem)
    }

    private var historyMetadata: String {
        let parts = [modeText, durationText, item.formattedDate].compactMap { $0 }
        return parts.joined(separator: " • ")
    }
}

private struct IOSSavedVoicesLibrarySection: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore
    @EnvironmentObject private var savedVoicesViewModel: SavedVoicesViewModel
    @Environment(\.presentIOSPlayerSheet) private var presentPlayerSheet

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
                                guard let item = IOSPlayerSheetItem.from(savedVoice: voice) else {
                                    return
                                }
                                IOSHaptics.selection()
                                presentPlayerSheet(item)
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

    @State private var isConfirmingDelete = false

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
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(voice.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(IOSAppTheme.textPrimary)

                        if voice.qualityHeadline != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                        }
                    }

                    if let headline = voice.qualityHeadline {
                        // Replace the default metadata line with the
                        // warning text when the saved voice fails the
                        // duration check. The bare triangle alone was
                        // too cryptic without sighted-user copy.
                        Label {
                            Text(headline)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .labelStyle(.titleAndIcon)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Reference quality warning")
                        .accessibilityHint(headline)
                    } else {
                        Text(voiceMetadata)
                            .font(.caption)
                            .foregroundStyle(IOSAppTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                    }
                    .iosAdaptiveUtilityButtonStyle(prominent: true, tint: IOSBrandTheme.library)

                    Menu {
                        Button("Use in Clone", action: onUseInVoiceCloning)
                        if FileManager.default.fileExists(atPath: voice.wavPath) {
                            ShareLink(item: URL(fileURLWithPath: voice.wavPath)) {
                                Label("Share reference clip", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button("Delete", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .iosAdaptiveUtilityButtonStyle(tint: IOSBrandTheme.library)
                    .accessibilityIdentifier("savedVoiceMenu_\(voice.id)")
                }
            }
        }
        .confirmationDialog(
            "Delete \(voice.name)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                IOSHaptics.warning()
                onDelete()
            }
            .accessibilityIdentifier("savedVoiceDeleteConfirm_\(voice.id)")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved voice and its reference clip are removed. This cannot be undone.")
        }
    }

    private var voiceMetadata: String {
        voice.hasTranscript
            ? "Saved voice • Transcript-backed"
            : "Saved voice • Audio-only fallback"
    }
}
