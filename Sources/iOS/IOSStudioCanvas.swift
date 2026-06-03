import SwiftUI
import QwenVoiceCore

private enum IOSStudioCanvasLayout {
    static let tabDockReservation: CGFloat = 97
    static let compactDockAreaHeight: CGFloat = 64
    static let completeDockAreaHeight: CGFloat = 135
    static let dockBottomPadding: CGFloat = 8
}

/// Unified Studio surface from design_references/Vocello iOS/studio.jsx.
/// Lays out (top → bottom): composer pad, setup-chip row, dock area with
/// idle / generating / complete states. The composer + meta + counter
/// match the design exactly; the dock area carries the Generate CTA,
/// the generating waveform, or the inline player depending on
/// `genState`.
///
/// Per-mode views provide the setup-chip row content via the
/// `setupChips` view builder and own the actual generation logic
/// through the closures. The canvas is stateless from a generation
/// point of view; it just renders the current `genState`.
struct IOSStudioCanvas<SetupChips: View>: View {
    let mode: GenerationMode
    @Binding var script: String
    let placeholder: String
    let modeMetaLabel: String
    let charLimit: Int
    let tint: Color
    let genState: IOSStudioGenState
    let errorMessage: String?
    let canGenerate: Bool
    let modelInstalled: Bool
    let modelDisplayName: String
    let setupChips: SetupChips
    let onGenerate: () -> Void
    let onCancel: () -> Void
    let onInstallModel: () -> Void
    let onPlayerDismiss: () -> Void
    let onPlayerExpand: (() -> Void)?

    init(
        mode: GenerationMode,
        script: Binding<String>,
        placeholder: String,
        modeMetaLabel: String,
        charLimit: Int = 800,
        tint: Color,
        genState: IOSStudioGenState,
        errorMessage: String? = nil,
        canGenerate: Bool,
        modelInstalled: Bool,
        modelDisplayName: String,
        @ViewBuilder setupChips: () -> SetupChips,
        onGenerate: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onInstallModel: @escaping () -> Void,
        onPlayerDismiss: @escaping () -> Void,
        onPlayerExpand: (() -> Void)? = nil
    ) {
        self.mode = mode
        self._script = script
        self.placeholder = placeholder
        self.modeMetaLabel = modeMetaLabel
        self.charLimit = charLimit
        self.tint = tint
        self.genState = genState
        self.errorMessage = errorMessage
        self.canGenerate = canGenerate
        self.modelInstalled = modelInstalled
        self.modelDisplayName = modelDisplayName
        self.setupChips = setupChips()
        self.onGenerate = onGenerate
        self.onCancel = onCancel
        self.onInstallModel = onInstallModel
        self.onPlayerDismiss = onPlayerDismiss
        self.onPlayerExpand = onPlayerExpand
    }

    // Plain @State (NOT @FocusState): this drives `IOSFlexibleTextEditor`'s
    // UIKit first-responder binding directly, set by the text view's
    // begin/end-editing delegate callbacks. A @FocusState here would never
    // hold its value (it isn't attached to any SwiftUI view via `.focused(...)`),
    // so it reverted to false after a tap and the editor's updateUIView then
    // immediately called resignFirstResponder — the keyboard never stayed up.
    // The sibling composers in IOSGenerationModeViews use the same @State pattern.
    @State private var isScriptFocused = false

    var body: some View {
        // B.3 closed (2026-05-21): composer is now `flex: 1` per the
        // design's `.vc-composer-pad`. The R5 / Phase 2 attempts kept
        // failing because SwiftUI's stock `TextEditor` doesn't
        // negotiate with `.frame(maxHeight: .infinity)` cleanly. The
        // fix that finally worked: a thin UIViewRepresentable<UITextView>
        // (`IOSFlexibleTextEditor` in `Sources/iOS/Studio/`) whose
        // `intrinsicContentSize.height` is `UIView.noIntrinsicMetric`.
        // With that out of the way, composerPad asks for the canvas's
        // leftover height via `.layoutPriority(1)` + maxHeight infinity;
        // chips + dock keep their natural sizes and pin against the
        // bottom safe-area inset chain owned by RootView (Phase 2).
        VStack(alignment: .leading, spacing: 0) {
            composerPad
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            setupRow
                .layoutPriority(2)
            dockArea
                .padding(.horizontal, 16)
                .padding(.bottom, IOSStudioCanvasLayout.dockBottomPadding)
                .frame(height: dockAreaHeight, alignment: .bottom)
                .layoutPriority(3)
        }
        // Bottom clearance: NavigationStack inside RootView doesn't
        // propagate the bottom chrome's safeAreaInset reservation to
        // the canvas cleanly. The React reference reserves 97 pt for
        // the tab dock; Studio's CTA / inline player then bottom-align
        // immediately above that reservation.
        .padding(.bottom, IOSStudioCanvasLayout.tabDockReservation)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keep the composer layout fixed: the keyboard OVERLAYS the bottom
        // (chips + Generate + tab dock stay put, covered) instead of reflowing
        // the whole canvas up into a cramped strip. The composer is the top,
        // flex element so the text you're typing stays visible above the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .iosAppAnimation(IOSDesignMotion.stateChange, value: genState)
    }

    private var dockAreaHeight: CGFloat {
        if case .complete = genState {
            return IOSStudioCanvasLayout.completeDockAreaHeight
        }
        return IOSStudioCanvasLayout.compactDockAreaHeight
    }

    // MARK: - Composer pad

    // R2 (2026-05-21): composer rewritten to match
    // `design_references/Vocello iOS/app.css` `.vc-composer-pad` +
    // `.vc-script`:
    //
    //   .vc-composer-pad { flex: 1; padding: 4px 20px 0; min-height: 0 }
    //   .vc-script       { background: transparent; border: none;
    //                      font: 500 22px/30px var(--font-display);
    //                      letter-spacing: -0.01em; padding: 8px 0 }
    //   .vc-script-meta  { font: 500 12px/14px; color: var(--fg-2);
    //                      letter-spacing: 0.02em }
    //
    // No card background, no border. The composer fills available
    // vertical space (canvas body removed its trailing Spacer for
    // exactly this reason). The meta row sits flush below the editor
    // with the mode label on the left and the counter on the right.
    private var composerPad: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if script.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 22, weight: .medium))
                        .tracking(-0.22)            // letter-spacing -0.01em ≈ -0.22pt at 22pt
                        .foregroundStyle(IOSAppTheme.textTertiary)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                IOSFlexibleTextEditor(
                    text: $script,
                    font: UIFont.systemFont(ofSize: 22, weight: .medium),
                    textColor: IOSAppTheme.textPrimaryUIColor,
                    tintColor: UIColor(tint),
                    isFocused: Binding(
                        get: { isScriptFocused },
                        set: { isScriptFocused = $0 }
                    )
                )
                .accessibilityIdentifier("textInput_textEditor")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: script) { _, newValue in
                let cap = charLimit + 200
                if newValue.count > cap {
                    script = String(newValue.prefix(cap))
                }
            }

            HStack {
                Text(modeMetaLabel)
                    .font(.system(size: 12, weight: .medium))
                    .tracking(0.24)               // letter-spacing 0.02em ≈ 0.24pt at 12pt
                    .foregroundStyle(IOSAppTheme.textSecondary)
                Spacer()
                Text("\(script.count) / \(charLimit)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(script.count > charLimit ? Color.orange : IOSAppTheme.textSecondary)
                    .accessibilityIdentifier("textInput_lengthCount")
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Setup row

    private var setupRow: some View {
        // Icon-only selector orbs, left-aligned as a cohesive cluster under the
        // section header (consistent whether the mode has 2 or 3 orbs — they don't
        // spread to the screen edges).
        HStack(alignment: .center, spacing: 18) {
            setupChips
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Dock area

    @ViewBuilder
    private var dockArea: some View {
        switch genState {
        case .idle where errorMessage != nil:
            errorBar
        case .idle where !modelInstalled:
            installCTA
        case .idle:
            generateCTA
        case .generating:
            generatingBar
        case .complete(let item):
            IOSStudioInlinePlayerCard(
                item: item,
                tint: tint,
                onDismiss: onPlayerDismiss,
                onExpand: onPlayerExpand
            )
        }
    }

    private var installCTA: some View {
        IOSPrimaryCTAButton(
            title: "Install \(modelDisplayName)",
            symbol: "arrow.down.circle.fill",
            tint: tint,
            isEnabled: true,
            action: onInstallModel
        )
        .accessibilityIdentifier("textInput_installModelButton")
    }

    private var errorBar: some View {
        Button {
            IOSHaptics.impact(.medium)
            onGenerate()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background {
                        Circle().fill(tint.opacity(0.14))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Generation failed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IOSAppTheme.textPrimary)
                    Text(errorMessage ?? "Try again.")
                        .font(.system(size: 11))
                        .foregroundStyle(IOSAppTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary.opacity(canGenerate ? 1 : 0.45))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.30), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canGenerate)
        .accessibilityIdentifier("textInput_generationError")
    }

    private var generateCTA: some View {
        IOSPrimaryCTAButton(
            title: "Generate",
            symbol: "sparkles",
            tint: tint,
            isEnabled: canGenerate,
            action: {
                IOSHaptics.impact(.medium)
                onGenerate()
            }
        )
        .accessibilityIdentifier("textInput_generateButton")
    }

    private var generatingBar: some View {
        HStack(spacing: 10) {
            IOSWaveformBars(
                seed: 42,
                barCount: 28,
                tint: tint,
                progress: 1.0,
                isAnimating: true
            )
            .frame(height: 32)

            VStack(alignment: .trailing, spacing: 2) {
                Text("Generating")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                Text(generatingSubline)
                    .font(.system(size: 11))
                    .foregroundStyle(IOSAppTheme.textSecondary)
            }

            Button {
                onCancel()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSAppTheme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle().fill(IOSAppTheme.glassSurfaceFillMuted.opacity(0.7))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("textInput_cancelButton")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.04))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private var generatingSubline: String {
        switch mode {
        case .custom: return "Rendering audio…"
        case .design: return "Designing voice…"
        case .clone: return "Cloning voice…"
        }
    }
}

// MARK: - Generation state

enum IOSStudioGenState: Equatable {
    case idle
    case generating
    case complete(IOSStudioInlinePlayerItem)
}

struct IOSStudioInlinePlayerItem: Equatable {
    let audioURL: URL
    let voiceName: String
    let modeLabel: String
    let mode: GenerationMode
    let transcript: String
    let waveformSeed: Int
    let autoplay: Bool

    static func == (lhs: IOSStudioInlinePlayerItem, rhs: IOSStudioInlinePlayerItem) -> Bool {
        lhs.audioURL == rhs.audioURL
    }

    var playerSheetItem: IOSPlayerSheetItem {
        IOSPlayerSheetItem(
            audioURL: audioURL,
            transcript: transcript,
            voiceName: voiceName,
            modeLabel: modeLabel,
            modeTint: IOSBrandTheme.modeColor(for: mode),
            subtitle: "Just now",
            avatarSeed: voiceName,
            avatarInitials: voiceName,
            waveformSeed: waveformSeed
        )
    }
}
