import SwiftUI
import Combine
import QwenVoiceCore

struct IOSEngineLifecycleToast: View {
    @EnvironmentObject private var ttsEngine: TTSEngineStore

    @State private var visibleState: EngineLifecycleState?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let state = visibleState, let descriptor = Self.descriptor(for: state) {
                toastBody(descriptor: descriptor)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .iosAppAnimation(IOSSelectionMotion.miniPlayerSlide, value: visibleState)
        .onReceive(ttsEngine.$extensionLifecycleState.removeDuplicates()) { newState in
            handle(newState: newState)
        }
        .onDisappear {
            dismissTask?.cancel()
            dismissTask = nil
        }
    }

    @ViewBuilder
    private func toastBody(descriptor: ToastDescriptor) -> some View {
        HStack(spacing: 10) {
            Image(systemName: descriptor.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(descriptor.tint)
            Text(descriptor.message)
                .font(IOSTypeStyle.subhead.font)
                .foregroundStyle(IOSAppTheme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .iosSubtleGlassSurface(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            tint: descriptor.tint
        )
        .padding(.horizontal, 16)
        .accessibilityIdentifier("engineLifecycleToast_\(descriptor.identifier)")
    }

    private func handle(newState: EngineLifecycleState) {
        guard Self.descriptor(for: newState) != nil else {
            // States with no toast clear any in-flight banner immediately.
            dismissTask?.cancel()
            visibleState = nil
            return
        }
        visibleState = newState
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if visibleState == newState {
                visibleState = nil
            }
        }
    }

    private struct ToastDescriptor {
        let identifier: String
        let message: String
        let symbol: String
        let tint: Color
    }

    private static func descriptor(for state: EngineLifecycleState) -> ToastDescriptor? {
        switch state {
        case .interrupted:
            return ToastDescriptor(
                identifier: "interrupted",
                message: "Engine paused. Generation will resume shortly.",
                symbol: "pause.circle",
                tint: .yellow
            )
        case .recovering:
            return ToastDescriptor(
                identifier: "recovering",
                message: "Engine recovering…",
                symbol: "arrow.triangle.2.circlepath",
                tint: .yellow
            )
        case .invalidated:
            return ToastDescriptor(
                identifier: "invalidated",
                message: "Engine restarted.",
                symbol: "arrow.clockwise.circle",
                tint: IOSBrandTheme.accent
            )
        case .failed:
            return ToastDescriptor(
                identifier: "failed",
                message: "Engine error. Try again, or open Settings → Model Downloads.",
                symbol: "exclamationmark.triangle",
                tint: .red
            )
        case .idle, .launching, .connected:
            return nil
        }
    }
}
