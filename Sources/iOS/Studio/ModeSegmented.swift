import SwiftUI
import QwenVoiceCore

/// Animated 3-way pill that switches between Studio modes
/// (Custom / Design / Clone). Mirrors `design_references/Vocello iOS/
/// chrome.jsx` `ModeSegmented` — selected text rides a flat accentWash
/// fill, with the pill sliding under the matched-geometry effect.
///
/// Reads + writes `AppModel.studioMode`.
struct ModeSegmented: View {
    @Bindable var appModel: AppModel

    @Namespace private var selectionPillNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(IOSGenerationSection.allCases) { section in
                Button {
                    select(section)
                } label: {
                    Text(section.compactTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(
                            section == appModel.studioMode
                                ? Theme.Text.primary
                                : Theme.Text.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 36)
                        .background {
                            if section == appModel.studioMode {
                                Capsule(style: .continuous)
                                    .fill(Color.clear)
                                    .iosSelectorPillGlass(tint: section.primaryActionTint)
                                    .matchedGeometryEffect(
                                        id: "selectionPill",
                                        in: selectionPillNamespace
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
                .iosAppAnimation(Theme.Motion.stateChange, value: appModel.studioMode)
                .accessibilityIdentifier("studioMode_\(section.rawValue)")
                .accessibilityAddTraits(section == appModel.studioMode ? .isSelected : [])
            }
        }
        .iosAppAnimation(Theme.Motion.modePillSlide, value: appModel.studioMode)
        .padding(2)
        .iosSelectorRailGlass(tint: appModel.studioMode.primaryActionTint)
        .padding(.vertical, 1)
        .sensoryFeedback(.selection, trigger: appModel.studioMode)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studioModeSelector")
    }

    private func select(_ section: IOSGenerationSection) {
        guard section != appModel.studioMode else { return }
        withAnimation(Theme.Motion.modePillSlide) {
            appModel.studioMode = section
        }
    }
}
