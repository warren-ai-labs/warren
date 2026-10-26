import SwiftUI
import WarrenDesignSystem
import WarrenObservation

/// The banner a stopped Tab carries above its last output.
///
/// A stopped Session is not a live pane, so the banner says three things and
/// stops there: that the Session stopped, why the Host says it stopped, and the
/// single action that continues it. There is no second action and no colour
/// beyond the shared quiet text tier — the choice on offer is the button, not a
/// palette.
public struct WarrenDesktopStoppedBanner: View {
    let reason: WarrenDesktopEndReason?
    let action: WarrenDesktopStoppedAction?
    /// True while an action is being started, which disables the one button
    /// instead of letting it be pressed twice.
    let isBusy: Bool
    /// The message of a failed action, shown in place of the reason line.
    let failure: String?
    /// The line the pane shows for output that could not be read, if any.
    let historyFailure: String?
    let onAction: () -> Void
    let onRetryHistory: () -> Void
    /// How many other stopped Sessions Resume All would continue. Zero hides
    /// the button.
    let resumeAllCount: Int
    let onResumeAll: () -> Void

    public init(
        reason: WarrenDesktopEndReason?,
        action: WarrenDesktopStoppedAction?,
        isBusy: Bool,
        failure: String?,
        historyFailure: String?,
        onAction: @escaping () -> Void,
        onRetryHistory: @escaping () -> Void,
        resumeAllCount: Int = 0,
        onResumeAll: @escaping () -> Void = {}
    ) {
        self.reason = reason
        self.action = action
        self.isBusy = isBusy
        self.failure = failure
        self.historyFailure = historyFailure
        self.onAction = onAction
        self.onRetryHistory = onRetryHistory
        self.resumeAllCount = resumeAllCount
        self.onResumeAll = onResumeAll
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        // One line and one button. A stopped pane is a picture of something that
        // already happened, so the bar stays as small as its sentence and sits
        // over the output in the pane's corner instead of spanning it.
        HStack(spacing: 8) {
            Image(systemName: "stop.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tokens.treeQuietText)
                .accessibilityHidden(true)
            Text(detailLine)
                .font(.system(size: 11))
                .foregroundStyle(historyFailure == nil && failure == nil ? tokens.mutedForeground : tokens.treeQuietText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(detailLine)
            if historyFailure != nil {
                Button("Retry output", action: onRetryHistory)
                    .buttonStyle(WarrenSecondaryButtonStyle())
                    .controlSize(.small)
                    .warrenSemanticElement(
                        id: "stopped-banner.retry",
                        role: .button,
                        label: "Retry output",
                        action: onRetryHistory
                    )
            }
            if let action {
                Button {
                    onAction()
                } label: {
                    if isBusy {
                        WarrenLoadingIndicator(size: 10, accessibilityLabel: action.label)
                    } else {
                        Text(action.label)
                    }
                }
                .buttonStyle(WarrenPrimaryButtonStyle())
                .controlSize(.small)
                .disabled(isBusy)
                .help(action.explanation)
                .accessibilityLabel("\(action.label) stopped Session")
                .warrenSemanticElement(
                    id: "stopped-banner.action",
                    role: .button,
                    label: action.label,
                    isEnabled: !isBusy,
                    action: onAction
                )
            }
            if resumeAllCount > 0 {
                Button("Resume All", action: onResumeAll)
                    .buttonStyle(WarrenSecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(isBusy)
                    .help(resumeAllExplanation)
                    .accessibilityLabel(resumeAllExplanation)
                    .warrenSemanticElement(
                        id: "stopped-banner.resume-all",
                        role: .button,
                        label: "Resume All",
                        value: "\(resumeAllCount)",
                        isEnabled: !isBusy,
                        action: onResumeAll
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Opaque, because this bar sits over live terminal output: a translucent
        // fill lets the text underneath read through the sentence.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tokens.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(tokens.border, lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .warrenSemanticElement(
            id: "stopped-banner",
            role: .group,
            label: "Stopped",
            value: detailLine
        )
    }

    private var resumeAllExplanation: String {
        let others = resumeAllCount == 1 ? "1 other stopped Session" : "\(resumeAllCount) other stopped Sessions"
        return action == .resume ? "Resume this and \(others)" : "Resume \(others)"
    }

    private var detailLine: String {
        if let historyFailure {
            return "The last output could not be read. \(historyFailure)"
        }
        if let failure {
            return failure
        }
        return reason?.detail ?? WarrenDesktopEndReason.unknown.detail
    }
}
