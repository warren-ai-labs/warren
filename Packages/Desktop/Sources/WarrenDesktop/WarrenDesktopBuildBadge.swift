import SwiftUI
import WarrenDesignSystem

/// Build provenance read from the app bundle. `scripts/build-app.sh` stamps
/// `build-variant.txt` (`build` for debug previews, `release` for release
/// builds); `WARREN_BUILD_VARIANT` covers `swift run` sessions.
enum WarrenBuildVariant {
    static let isBuild: Bool = {
        if let url = Bundle.main.url(forResource: "build-variant", withExtension: "txt"),
           let value = try? String(contentsOf: url, encoding: .utf8) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines) == "build"
        }
        return ProcessInfo.processInfo.environment["WARREN_BUILD_VARIANT"] == "build"
    }()
}

/// Compact update state shown beside the build provenance marker.
public enum WarrenDesktopUpdateStatus: Equatable, Sendable {
    case none
    case available(version: String)
    case updating
    case failed

    var label: String? {
        switch self {
        case .none:
            nil
        case .available:
            "Update"
        case .updating:
            "Updating…"
        case .failed:
            "Failed"
        }
    }

    var isActionable: Bool {
        switch self {
        case .available, .failed:
            true
        case .none, .updating:
            false
        }
    }

    var accessibilityLabel: String? {
        switch self {
        case .none:
            nil
        case .available(let version):
            "New Warren version available: \(version)"
        case .updating:
            "Updating Warren"
        case .failed:
            "Warren update failed"
        }
    }

    var helpText: String? {
        switch self {
        case .none:
            nil
        case .available(let version):
            "Warren \(version) is ready to install. Click to install it."
        case .updating:
            "Warren is installing an update."
        case .failed:
            "The Warren update failed. Click to retry."
        }
    }
}

/// Small top-of-window marker that tells preview builds apart from release
/// installs when several Warren windows are open side by side.
struct WarrenDesktopBuildBadge: View {
    let updateStatus: WarrenDesktopUpdateStatus
    let showsBuildMarker: Bool
    let onUpdateAction: () -> Void

    init(
        updateStatus: WarrenDesktopUpdateStatus = .none,
        showsBuildMarker: Bool = true,
        onUpdateAction: @escaping () -> Void = {}
    ) {
        self.updateStatus = updateStatus
        self.showsBuildMarker = showsBuildMarker
        self.onUpdateAction = onUpdateAction
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var isStatusHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.small) {
            if showsBuildMarker {
                Text("BUILD")
                    .fontWeight(.medium)
                    .foregroundStyle(tokens.amber)
            }

            if showsBuildMarker {
                Spacer(minLength: WarrenSpacing.medium)
            }
            statusControl(tokens: tokens)
        }
        .font(WarrenTypography.sectionLabel)
        .tracking(1.0)
        .frame(minWidth: showsBuildMarker ? 132 : 0, alignment: .trailing)
        .frame(height: 28, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .help(helpText)
    }

    @ViewBuilder
    private func statusControl(tokens: WarrenColorTokens) -> some View {
        if let label = updateStatus.label {
            if updateStatus.isActionable {
                Button(action: onUpdateAction) {
                    statusLabel(label: label, tokens: tokens)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, WarrenSpacing.xs)
                .padding(.vertical, WarrenSpacing.xxs)
                .background(
                    color(for: updateStatus, tokens: tokens)
                        .opacity(isStatusHovered ? 0.10 : 0.04)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.xs)
                        .stroke(
                            color(for: updateStatus, tokens: tokens)
                                .opacity(isStatusHovered ? 0.45 : 0.20),
                            lineWidth: WarrenSpacing.hairline
                        )
                }
                .clipShape(.rect(cornerRadius: WarrenRadius.xs))
                .contentShape(.rect(cornerRadius: WarrenRadius.xs))
                .scaleEffect(isStatusHovered ? 1.01 : 1)
                .onHover { isStatusHovered = $0 }
                .animation(.easeOut(duration: WarrenMotion.feedbackDuration), value: isStatusHovered)
                .accessibilityLabel(updateStatus.accessibilityLabel ?? label)
                .accessibilityHint("Install or retry the Warren update")
            } else {
                statusLabel(label: label, tokens: tokens)
            }
        }
    }

    @ViewBuilder
    private func statusLabel(label: String, tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            switch updateStatus {
            case .available:
                WarrenStatusIndicator(
                    color: color(for: updateStatus, tokens: tokens),
                    isActive: true,
                    size: 4,
                    accessibilityLabel: "Update ready"
                )
            case .updating:
                WarrenBrailleSpinner(size: 10, accessibilityLabel: "Updating Warren")
            case .failed:
                EmptyView()
            case .none:
                EmptyView()
            }
            Text(label)
                .font(updateStatus == .failed
                    ? .system(size: 12, weight: .light)
                    : WarrenTypography.sectionLabel)
                .foregroundStyle(color(for: updateStatus, tokens: tokens))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func color(
        for status: WarrenDesktopUpdateStatus,
        tokens: WarrenColorTokens
    ) -> Color {
        switch status {
        case .none:
            tokens.mutedForeground
        case .available:
            tokens.info
        case .updating:
            tokens.amber
        case .failed:
            tokens.destructive
        }
    }

    private var helpText: String {
        ["This window is a locally built preview", updateStatus.helpText]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
