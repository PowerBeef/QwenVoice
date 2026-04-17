import SwiftUI

struct VoicesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showAddVoice = false
    @State private var selectedVoice: Voice?

    @Binding var recentlyUsed: [Voice]
    @Binding var customVoices: [Voice]
    var onVoiceSelected: ((Voice) -> Void)?

    var filteredRecentlyUsed: [Voice] {
        if searchText.isEmpty {
            return recentlyUsed
        }
        return recentlyUsed.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    var filteredCustomVoices: [Voice] {
        if searchText.isEmpty {
            return customVoices
        }
        return customVoices.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    #if os(iOS)
    private let sectionSpacing: CGFloat = 16
    #else
    private let sectionSpacing: CGFloat = 24
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    // Search bar
                    SearchBar(text: $searchText)
                        .padding(.horizontal)

                    // Add new voice button
                    AddVoiceButton {
                        showAddVoice = true
                    }
                    .padding(.horizontal)

                    // Recently used section
                    if !filteredRecentlyUsed.isEmpty {
                        RecentlyUsedSection(
                            voices: filteredRecentlyUsed,
                            onVoiceTap: { voice in
                                selectedVoice = voice
                                onVoiceSelected?(voice)
                            }
                        )
                        .padding(.horizontal)
                    }

                    // Your voices section
                    if !filteredCustomVoices.isEmpty {
                        YourVoicesSection(
                            voices: filteredCustomVoices,
                            onVoiceTap: { voice in
                                selectedVoice = voice
                                onVoiceSelected?(voice)
                            },
                            onDelete: { voice in
                                customVoices.removeAll { $0.id == voice.id }
                            }
                        )
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Voices")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showAddVoice) {
                AddVoiceView { newVoice in
                    customVoices.append(newVoice)
                }
            }
        }
    }
}

// MARK: - Search Bar

struct SearchBar: View {
    @Binding var text: String

    #if os(iOS)
    private let padding: CGFloat = 10
    private let cornerRadius: CGFloat = 10
    #else
    private let padding: CGFloat = 12
    private let cornerRadius: CGFloat = 12
    #endif

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Search", text: $text)
                .font(.footnote)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(padding)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Add Voice Button

struct AddVoiceButton: View {
    var action: () -> Void

    #if os(iOS)
    private let circleSize: CGFloat = 36
    private let iconFont: Font = .callout
    private let titleFont: Font = .footnote
    private let subtitleFont: Font = .caption
    #else
    private let circleSize: CGFloat = 50
    private let iconFont: Font = .title2
    private let titleFont: Font = .body
    private let subtitleFont: Font = .subheadline
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.black)
                        .frame(width: circleSize, height: circleSize)

                    Image(systemName: "plus")
                        .font(iconFont)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Add a new voice")
                        .font(titleFont)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text("Create or clone a voice")
                        .font(subtitleFont)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recently Used Section

struct RecentlyUsedSection: View {
    let voices: [Voice]
    var onVoiceTap: ((Voice) -> Void)?

    #if os(iOS)
    private let titleFont: Font = .subheadline
    private let subtitleFont: Font = .caption
    #else
    private let titleFont: Font = .title2
    private let subtitleFont: Font = .subheadline
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recently used")
                    .font(titleFont)
                    .fontWeight(.bold)

                Text("Voices you've used recently")
                    .font(subtitleFont)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(voices) { voice in
                        VoiceChip(voice: voice) {
                            onVoiceTap?(voice)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Your Voices Section

struct YourVoicesSection: View {
    let voices: [Voice]
    var onVoiceTap: ((Voice) -> Void)?
    var onDelete: ((Voice) -> Void)?

    #if os(iOS)
    private let titleFont: Font = .subheadline
    private let subtitleFont: Font = .caption
    #else
    private let titleFont: Font = .title2
    private let subtitleFont: Font = .subheadline
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Voices")
                    .font(titleFont)
                    .fontWeight(.bold)

                Text("Voices you've created")
                    .font(subtitleFont)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(voices) { voice in
                    VoiceRow(
                        voice: voice,
                        showDeleteButton: true,
                        onDelete: { onDelete?(voice) },
                        onTap: { onVoiceTap?(voice) }
                    )
                }
            }
        }
    }
}

#Preview {
    VoicesView(
        recentlyUsed: .constant(Voice.samples),
        customVoices: .constant(Voice.customVoices)
    )
}
