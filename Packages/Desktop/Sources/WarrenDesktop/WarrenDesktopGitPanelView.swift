import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenObservation

private enum WarrenGitPanelStyle {
    static let headerHeight: CGFloat = 36
    static let pullRequestHeightRatio: CGFloat = 0.40
    static let changesHeightRatio: CGFloat = 0.38
    static let changesMaximumHeight: CGFloat = 320
    static let paneHeaderFont = Font.system(size: 12, weight: .semibold)
    static let trackingLabelFont = Font.system(size: 11, weight: .semibold)
    static let metadataFont = Font.system(size: 11, weight: .regular)
}

// MARK: - Panel

/// Right-side Git panel mirroring the web client's `GitPanel` layout: a fixed
/// Branch section followed by collapsible Checkout, Pull Request, Changes and
/// History panes.
public struct WarrenDesktopGitPanelView: View {
    let workspaceName: String
    @ObservedObject var model: WarrenDesktopGitPanelModel
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        workspaceName: String,
        model: WarrenDesktopGitPanelModel,
        onClose: @escaping () -> Void
    ) {
        self.workspaceName = workspaceName
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            header(tokens: tokens)
            if let error = model.errorMessage {
                errorBanner(error, tokens: tokens)
            }
            content(tokens: tokens)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tokens.chromeSurface)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tokens.border)
                .frame(width: WarrenSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Git panel")
    }

    private func header(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Text(panelTitle)
                .font(WarrenTypography.navigationGroup)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: WarrenSpacing.compact)
            if model.showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .help("Refreshing")
                    .accessibilityLabel("Refreshing")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .frame(
                width: WarrenLayoutMetrics.compactControlHeight,
                height: WarrenLayoutMetrics.compactControlHeight
            )
            .contentShape(.rect)
            .foregroundStyle(tokens.mutedForeground)
            .help("Close Git panel")
            .accessibilityLabel("Close Git panel")
            .warrenSemanticElement(
                id: "git.panel.close",
                role: .button,
                label: "Close Git panel",
                action: onClose
            )
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .frame(height: WarrenGitPanelStyle.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
        }
    }

    private var panelTitle: String {
        guard let branch = model.panel?.branch, !branch.isEmpty else {
            return workspaceName.isEmpty ? "Git" : workspaceName
        }
        return branch
    }

    private func errorBanner(_ error: String, tokens: WarrenColorTokens) -> some View {
        Text(error)
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.destructive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WarrenSpacing.compact)
            .background(tokens.destructive.opacity(0.08))
            .clipShape(.rect(cornerRadius: WarrenRadius.small))
            .overlay {
                RoundedRectangle(cornerRadius: WarrenRadius.small)
                    .stroke(tokens.destructive, lineWidth: WarrenSpacing.hairline)
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .padding(.top, WarrenSpacing.compact)
            .accessibilityLabel("Git error: \(error)")
    }

    private func content(tokens: WarrenColorTokens) -> some View {
        Group {
            if model.showsLoading {
                loadingState(tokens: tokens)
            } else {
                GeometryReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        WarrenGitBranchSection(model: model)
                        WarrenGitPaneHeader(
                            title: "Checkout",
                            systemImage: "arrow.triangle.branch",
                            isOpen: model.openPanes.contains(.checkout),
                            onToggle: { model.togglePane(.checkout) }
                        )
                        if model.openPanes.contains(.checkout) {
                            WarrenGitCheckoutPane(model: model)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if model.panel?.remote != nil {
                            WarrenGitPaneHeader(
                                title: "Pull Request",
                                systemImage: "arrow.triangle.merge",
                                isOpen: model.openPanes.contains(.pr),
                                onToggle: { model.togglePane(.pr) }
                            )
                            if model.openPanes.contains(.pr) {
                                ScrollView {
                                    WarrenGitPullRequestPane(model: model)
                                }
                                .frame(maxHeight: proxy.size.height * WarrenGitPanelStyle.pullRequestHeightRatio)
                            }
                        }
                        WarrenGitPaneHeader(
                            title: model.changeCount > 0 ? "Changes (\(model.changeCount))" : "Changes",
                            isOpen: model.openPanes.contains(.changes),
                            onToggle: { model.togglePane(.changes) }
                        )
                        if model.openPanes.contains(.changes) {
                            ScrollView {
                                WarrenGitChangesPane(model: model)
                            }
                            .frame(
                                maxHeight: min(
                                    WarrenGitPanelStyle.changesMaximumHeight,
                                    proxy.size.height * WarrenGitPanelStyle.changesHeightRatio
                                )
                            )
                        }
                        WarrenGitPaneHeader(
                            title: "History",
                            detail: historyScope,
                            isOpen: model.openPanes.contains(.history),
                            onToggle: { model.togglePane(.history) }
                        )
                        if model.openPanes.contains(.history) {
                            ScrollView {
                                WarrenGitHistoryPane(model: model)
                            }
                            .frame(maxHeight: .infinity)
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.vertical, WarrenSpacing.small)
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height,
                        alignment: .topLeading
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyScope: String? {
        guard let panel = model.panel,
              panel.mainBranch != nil,
              !panel.merged,
              panel.operation == nil else { return nil }
        return "not in \(panel.mainBranch ?? "")"
    }

    private func loadingState(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.standard) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(model.busy ? "\(model.actionLabel)…" : "Loading…")
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.busy ? "\(model.actionLabel)" : "Loading Git panel")
    }
}

// MARK: - Branch section

private struct WarrenGitBranchSection: View {
    @ObservedObject var model: WarrenDesktopGitPanelModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            if let operation = model.panel?.operation, !operation.isEmpty {
                Text("\(model.operationLabel) in progress — resolve it before pushing or pulling")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(WarrenSpacing.compact)
                    .background(tokens.destructive.opacity(0.08))
                    .clipShape(.rect(cornerRadius: WarrenRadius.xs))
                    .overlay {
                        RoundedRectangle(cornerRadius: WarrenRadius.xs)
                            .stroke(tokens.destructive.opacity(0.4), lineWidth: WarrenSpacing.hairline)
                    }
                    .accessibilityLabel("\(model.operationLabel) in progress")
            }

            if let upstream = model.panel?.upstream, !upstream.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.small) {
                    Text("Tracks")
                        .font(WarrenGitPanelStyle.trackingLabelFont)
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                    Text(upstream)
                        .font(WarrenTypography.code)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let mainBranch = model.panel?.mainBranch,
               !mainBranch.isEmpty,
               model.panel?.operation == nil,
               model.panel?.merged == true {
                Text("Merged into \(mainBranch)")
                    .font(WarrenTypography.badge)
                    .foregroundStyle(tokens.success)
                    .padding(.horizontal, WarrenSpacing.small)
                    .padding(.vertical, 2)
                    .background(tokens.success.opacity(0.1))
                    .clipShape(.rect(cornerRadius: WarrenRadius.small))
            }

            if let upstream = model.panel?.upstream, !upstream.isEmpty {
                syncState(tokens: tokens, upstream: upstream)
            }

            if let remote = model.panel?.remote, !remote.isEmpty {
                Text(remote)
                    .font(WarrenTypography.externalIDEPath)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Remote \(remote)")
            }

            HStack(spacing: WarrenSpacing.xxs) {
                WarrenGitActionButton(
                    label: "Refresh",
                    systemImage: "arrow.clockwise",
                    tint: tokens.mutedForeground,
                    expands: true,
                    isBusy: false,
                    disabled: model.busy,
                    action: model.refresh
                )
                WarrenGitActionButton(
                    label: model.activeAction == .pull ? "Pulling…" : "Pull",
                    systemImage: "arrow.down",
                    tint: tokens.info,
                    expands: true,
                    isBusy: model.activeAction == .pull,
                    disabled: model.busy || model.panel == nil,
                    action: model.pull
                )
                WarrenGitActionButton(
                    label: model.activeAction == .push ? "Pushing…" : "Push",
                    systemImage: "arrow.up",
                    tint: tokens.highlight,
                    expands: true,
                    isBusy: model.activeAction == .push,
                    disabled: model.busy || model.panel == nil,
                    action: pushOrCommit
                )
            }

            if model.commitOpen {
                commitBox(tokens: tokens)
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .padding(.vertical, WarrenSpacing.small)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pushOrCommit() {
        let changes = model.panel?.changes ?? []
        if model.panel != nil, !changes.isEmpty {
            model.openCommitForm()
        } else {
            model.push()
        }
    }

    private func syncState(tokens: WarrenColorTokens, upstream: String) -> some View {
        let ahead = model.panel?.ahead ?? 0
        let behind = model.panel?.behind ?? 0
        return HStack(spacing: WarrenSpacing.compact) {
            if ahead > 0 {
                Text("↑ \(ahead) ahead")
                    .foregroundStyle(tokens.foreground)
            }
            if behind > 0 {
                Text("↓ \(behind) behind")
                    .foregroundStyle(tokens.warning)
            }
            if ahead <= 0, behind <= 0 {
                Text("Synced with \(upstream)")
                    .foregroundStyle(tokens.success)
            }
        }
        .font(WarrenTypography.supporting)
        .accessibilityElement(children: .combine)
    }

    private func commitBox(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            Text("Commit changes before pushing")
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
            TextField("Commit message", text: $model.commitMessage)
                .textFieldStyle(.plain)
                .font(WarrenTypography.supporting)
                .padding(.horizontal, WarrenSpacing.small)
                .padding(.vertical, 5)
                .background(tokens.inputSurface)
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .onSubmit(submitCommit)
                .onExitCommand { model.cancelCommit() }
            HStack(spacing: WarrenSpacing.small) {
                WarrenGitActionButton(
                    label: model.activeAction == .commit ? "Committing…" : "Commit & Push",
                    isBusy: model.activeAction == .commit,
                    disabled: model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy,
                    action: submitCommit
                )
                WarrenGitActionButton(
                    label: "Cancel",
                    isBusy: false,
                    disabled: model.busy,
                    action: model.cancelCommit
                )
            }
        }
        .padding(WarrenSpacing.small)
        .background(tokens.muted.opacity(0.5))
        .clipShape(.rect(cornerRadius: WarrenRadius.medium))
    }

    private func submitCommit() {
        let message = model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        model.commitAndPush(message: message)
    }
}

// MARK: - Checkout pane

private struct WarrenGitCheckoutPane: View {
    @ObservedObject var model: WarrenDesktopGitPanelModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            if model.createBranchMode {
                TextField("New branch name", text: $model.newBranchName)
                    .textFieldStyle(.plain)
                    .font(WarrenTypography.supporting)
                    .padding(.horizontal, WarrenSpacing.small)
                    .padding(.vertical, 5)
                    .background(tokens.inputSurface)
                    .clipShape(.rect(cornerRadius: WarrenRadius.small))
                    .onSubmit(submitCheckout)
                    .onExitCommand { model.toggleCreateMode() }
            } else {
                Picker("Branch", selection: $model.branchSelection) {
                    Text("Switch to a branch…").tag("")
                    ForEach(model.localBranches(), id: \.self) { branch in
                        Text(branch).tag(branch)
                    }
                    ForEach(model.remoteBranches(), id: \.self) { branch in
                        Text("\(branch) (remote)").tag(branch)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(model.localBranches().isEmpty && model.remoteBranches().isEmpty)
            }

            HStack(spacing: WarrenSpacing.xs) {
                WarrenGitActionButton(
                    label: model.activeAction == .checkout
                        ? "Switching…"
                        : (model.createBranchMode ? "Create branch" : "Switch branch"),
                    tint: tokens.highlight,
                    expands: true,
                    isBusy: model.activeAction == .checkout,
                    disabled: model.busy || (model.createBranchMode
                        ? model.newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        : model.branchSelection.isEmpty),
                    action: submitCheckout
                )
                WarrenGitActionButton(
                    label: model.createBranchMode ? "Existing branch" : "New branch",
                    tint: tokens.mutedForeground,
                    expands: true,
                    isBusy: false,
                    disabled: model.busy,
                    action: model.toggleCreateMode
                )
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .padding(.bottom, WarrenSpacing.compact)
    }

    private func submitCheckout() {
        if model.createBranchMode {
            let name = model.newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            model.checkout(branch: name, create: true)
        } else if !model.branchSelection.isEmpty {
            model.checkout(branch: model.branchSelection, create: false)
        }
    }
}

// MARK: - Pull Request pane

private struct WarrenGitPullRequestPane: View {
    @ObservedObject var model: WarrenDesktopGitPanelModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            if let panel = model.panel,
               panel.aheadOfMain > 0,
               let mainBranch = panel.mainBranch {
                Text("↑ \(panel.aheadOfMain) commit\(panel.aheadOfMain == 1 ? "" : "s") ahead of \(mainBranch)")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.info)
                    .accessibilityElement(children: .combine)
            }
            if let pr = model.panel?.pullRequest {
                WarrenGitPullRequestCard(pr: pr, stateLabel: model.pullRequestStateLabel, tokens: tokens)
            } else if let error = model.panel?.pullRequestError, !error.isEmpty {
                Text(error)
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.canCreatePullRequest {
                if model.prOpen {
                    pullRequestForm(tokens: tokens)
                } else {
                    WarrenGitActionButton(
                        label: "Create pull request",
                        tint: tokens.highlight,
                        isBusy: false,
                        disabled: model.busy,
                        action: model.openPullRequestForm
                    )
                }
            } else {
                Text("No pull request")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .padding(.bottom, WarrenSpacing.compact)
    }

    private func pullRequestForm(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            TextField("Pull request title", text: $model.prTitle)
                .textFieldStyle(.plain)
                .font(WarrenTypography.supporting)
                .padding(.horizontal, WarrenSpacing.small)
                .padding(.vertical, 5)
                .background(tokens.inputSurface)
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .onSubmit(submitPullRequest)
                .onExitCommand { model.cancelPullRequestForm() }
            TextEditor(text: $model.prBody)
                .font(WarrenTypography.supporting)
                .scrollContentBackground(.hidden)
                .padding(WarrenSpacing.small)
                .background(tokens.inputSurface)
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .frame(height: 72)
                .onExitCommand { model.cancelPullRequestForm() }
            if let mainBranch = model.panel?.mainBranch {
                Text("Merge into \(mainBranch) from \(model.panel?.branch ?? "")")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
            }
            HStack(spacing: WarrenSpacing.small) {
                WarrenGitActionButton(
                    label: model.activeAction == .prCreate ? "Creating…" : "Create pull request",
                    tint: tokens.highlight,
                    isBusy: model.activeAction == .prCreate,
                    disabled: model.prTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy,
                    action: submitPullRequest
                )
                WarrenGitActionButton(
                    label: "Cancel",
                    isBusy: false,
                    disabled: model.busy,
                    action: model.cancelPullRequestForm
                )
            }
        }
    }

    private func submitPullRequest() {
        let title = model.prTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        model.createPullRequest(title: title, body: model.prBody)
    }
}

private struct WarrenGitPullRequestCard: View {
    let pr: WarrenDesktopGitPullRequest
    let stateLabel: String
    let tokens: WarrenColorTokens

    var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            HStack(spacing: WarrenSpacing.small) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.highlight)
                    .accessibilityHidden(true)
                if let number = pr.number {
                    Text("#\(number)")
                        .font(WarrenTypography.externalIDEPath)
                        .foregroundStyle(tokens.mutedForeground)
                }
                if !stateLabel.isEmpty {
                    Text(stateLabel)
                        .font(WarrenTypography.badge)
                        .foregroundStyle(stateColor)
                        .textCase(.uppercase)
                }
                if pr.draft {
                    Text("Draft")
                        .font(WarrenTypography.badge)
                        .foregroundStyle(tokens.mutedForeground)
                        .textCase(.uppercase)
                }
            }
            Text(pr.title)
                .font(WarrenTypography.bodyEmphasis)
                .lineLimit(2)
            if let author = pr.author {
                let base = pr.base ?? ""
                let head = pr.head ?? ""
                Text([author, base.isEmpty || head.isEmpty ? nil : "\(base) ← \(head)"]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(WarrenTypography.navigationMeta)
                    .foregroundStyle(tokens.mutedForeground)
            }
            if let body = pr.body, !body.isEmpty {
                Text(body)
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(8)
            }
            if let urlString = pr.url, let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Open pull request ↗")
                        .font(WarrenTypography.chromeLabel)
                }
                .buttonStyle(WarrenGitActionButtonStyle(tokens: tokens))
                .foregroundStyle(tokens.info)
                .help("Open \(urlString)")
                .accessibilityLabel("Open pull request \(urlString)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WarrenSpacing.small)
        .accessibilityElement(children: .contain)
    }

    private var stateColor: Color {
        switch pr.state {
        case "merged": tokens.info
        case "closed": tokens.mutedForeground
        default: tokens.success
        }
    }
}

// MARK: - Changes pane

private struct WarrenGitChangesPane: View {
    @ObservedObject var model: WarrenDesktopGitPanelModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            let staged = model.stagedChanges
            let unstaged = model.unstagedChanges
            if !staged.isEmpty {
                let summary = WarrenDesktopGitDiffSummary.summary(of: staged)
                HStack(spacing: WarrenSpacing.small) {
                    Text("Staged (\(staged.count))")
                        .font(WarrenGitPanelStyle.paneHeaderFont)
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(tokens.mutedForeground)
                    WarrenGitDiffCounts(added: summary.added, deleted: summary.deleted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WarrenSpacing.compact)
                .padding(.top, WarrenSpacing.xs)
                WarrenGitChangeList(
                    changes: staged,
                    selectedKey: model.selectedKey,
                    onOpen: { change in model.openFile(change: change) }
                )
            }
            if !unstaged.isEmpty {
                WarrenGitChangeList(
                    changes: unstaged,
                    selectedKey: model.selectedKey,
                    onOpen: { change in model.openFile(change: change) }
                )
            }
            if staged.isEmpty, unstaged.isEmpty {
                Text("No changes")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, WarrenSpacing.compact)
                    .padding(.vertical, WarrenSpacing.small)
            }
        }
        .padding(.bottom, WarrenSpacing.compact)
    }
}

private struct WarrenGitChangeList: View {
    let changes: [WarrenDesktopGitChange]
    let selectedKey: String?
    let onOpen: (WarrenDesktopGitChange) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                WarrenGitChangeRow(
                    change: change,
                    isSelected: selectedKey == Self.key(for: change),
                    onOpen: { onOpen(change) }
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private static func key(for change: WarrenDesktopGitChange) -> String {
        "\(change.staged ? "s" : "u"):\(change.path)"
    }
}

private struct WarrenGitChangeRow: View {
    let change: WarrenDesktopGitChange
    let isSelected: Bool
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: onOpen) {
            HStack(spacing: WarrenSpacing.small) {
                Text(WarrenDesktopGitStatusLabel.symbol(for: change.status))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(tokens: tokens))
                    .frame(width: 18, alignment: .center)
                    .background(tokens.tertiaryWash)
                    .clipShape(.rect(cornerRadius: WarrenRadius.xs))
                    .accessibilityLabel(WarrenDesktopGitStatusLabel.label(for: change.status))
                Text(change.path)
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let renameFrom = change.renameFrom, !renameFrom.isEmpty {
                    Text("← \(renameFrom)")
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: WarrenSpacing.xs)
                WarrenGitDiffCounts(added: change.added, deleted: change.deleted)
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .padding(.vertical, WarrenSpacing.xxs)
            .contentShape(.rect)
            .background(isSelected ? tokens.fillSelected : (hovered ? tokens.fillHover : .clear))
            .animation(.easeOut(duration: 0.1), value: isSelected)
            .animation(.easeOut(duration: 0.1), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(WarrenDesktopGitStatusLabel.label(for: change.status)) \(change.path)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func statusColor(tokens: WarrenColorTokens) -> Color {
        switch change.status {
        case "D": tokens.destructive
        case "A", "C": tokens.success
        case "M", "T", "U": tokens.warning
        default: tokens.info
        }
    }
}

// MARK: - History pane

private struct WarrenGitHistoryPane: View {
    @ObservedObject var model: WarrenDesktopGitPanelModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let commits = model.historyCommits
        VStack(alignment: .leading, spacing: 0) {
            if commits.isEmpty {
                Text(model.panel?.mainBranch != nil && model.panel?.operation == nil
                    ? "All commits are in \(model.panel?.mainBranch ?? "")"
                    : "No commits")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, WarrenSpacing.compact)
                    .padding(.vertical, WarrenSpacing.small)
            } else {
                ForEach(commits, id: \.hash) { commit in
                    WarrenGitCommitRow(
                        commit: commit,
                        isExpanded: model.expandedCommits.contains(commit.hash),
                        selectedKey: model.selectedKey,
                        onToggle: { model.toggleCommitExpanded(commit.hash) },
                        onOpenFile: { change in model.openFile(change: change, commit: commit.hash) }
                    )
                }
            }
        }
        .padding(.bottom, WarrenSpacing.compact)
    }
}

private struct WarrenGitCommitRow: View {
    let commit: WarrenDesktopGitCommit
    let isExpanded: Bool
    let selectedKey: String?
    let onToggle: () -> Void
    let onOpenFile: (WarrenDesktopGitChange) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    Text(commit.subject)
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: WarrenSpacing.xs) {
                        Text(commit.short)
                            .font(WarrenTypography.externalIDEPath)
                        Text("·")
                        Text(commit.author)
                        Text("·")
                        Text(WarrenDesktopGitRelativeTime.string(from: commit.time))
                        Spacer(minLength: WarrenSpacing.xs)
                        let summary = WarrenDesktopGitDiffSummary.summary(of: commit.files)
                        if summary.added > 0 || summary.deleted > 0 {
                            WarrenGitDiffCounts(added: summary.added, deleted: summary.deleted)
                        }
                    }
                    .font(WarrenGitPanelStyle.metadataFont)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                }
                .padding(.horizontal, WarrenSpacing.compact)
                .padding(.vertical, WarrenSpacing.small)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(commit.subject), \(commit.short)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(commit.files.enumerated()), id: \.offset) { _, change in
                        WarrenGitChangeRow(
                            change: change,
                            isSelected: selectedKey == "\(commit.hash):\(change.path)",
                            onOpen: { onOpenFile(change) }
                        )
                    }
                }
                .padding(.leading, WarrenSpacing.compact)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Shared controls

private struct WarrenGitDiffCounts: View {
    let added: Int
    let deleted: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.xs) {
            if added > 0 {
                Text("+\(added)")
                    .foregroundStyle(tokens.success)
            }
            if deleted > 0 {
                Text("-\(deleted)")
                    .foregroundStyle(tokens.destructive)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(diffSummaryLabel)
    }

    private var diffSummaryLabel: String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        return parts.joined(separator: ", ")
    }
}

private struct WarrenGitPaneHeader: View {
    let title: String
    let systemImage: String?
    let detail: String?
    let isOpen: Bool
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    init(
        title: String,
        systemImage: String? = nil,
        detail: String? = nil,
        isOpen: Bool,
        onToggle: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.isOpen = isOpen
        self.onToggle = onToggle
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: onToggle) {
            HStack(spacing: WarrenSpacing.small) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(WarrenGitPanelStyle.paneHeaderFont)
                    .tracking(0.5)
                    .foregroundStyle(tokens.mutedForeground)
                    .textCase(.uppercase)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 10)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .padding(.vertical, WarrenSpacing.xs)
            .contentShape(.rect)
            .background(hovered ? tokens.fillHover : .clear)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(title) panel")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }
}

private struct WarrenGitActionButton: View {
    let label: String
    let systemImage: String?
    let tint: Color?
    let expands: Bool
    let isBusy: Bool
    let disabled: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    init(
        label: String,
        systemImage: String? = nil,
        tint: Color? = nil,
        expands: Bool = false,
        isBusy: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.expands = expands
        self.isBusy = isBusy
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            HStack(spacing: WarrenSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .accessibilityHidden(true)
                }
                Text(label)
                    .lineLimit(1)
            }
        }
        .buttonStyle(WarrenGitActionButtonStyle(tokens: tokens))
        .frame(maxWidth: expands ? .infinity : nil)
        .foregroundStyle(tint ?? tokens.foreground)
        .background(hovered ? tokens.fillHover : .clear)
        .clipShape(.rect(cornerRadius: WarrenRadius.xs))
        .disabled(disabled)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityValue(isBusy ? "In progress" : "")
    }
}

private struct WarrenGitActionButtonStyle: ButtonStyle {
    let tokens: WarrenColorTokens

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WarrenTypography.chromeLabel)
            .padding(.horizontal, WarrenSpacing.small + 2)
            .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
            .background(configuration.isPressed ? tokens.fillSelected : .clear)
            .clipShape(.rect(cornerRadius: WarrenRadius.xs))
            .opacity(isEnabled ? 1 : 0.42)
    }
}

// MARK: - File diff viewer

private enum WarrenGitDiffMetrics {
    static let lineNumberWidth: CGFloat = 32
    static let indicatorWidth: CGFloat = 16
    static let lineHeight: CGFloat = 18
    static let codeFont = Font.system(size: 12, design: .monospaced)
    static let lineNumberFont = Font.system(size: 11, design: .monospaced)
}

/// Full-area file diff viewer, replicating the web client's `FileDiffView`.
/// The terminal stays mounted underneath while this view replaces its surface.
public struct WarrenDesktopGitDiffView: View {
    @ObservedObject var model: WarrenDesktopGitPanelModel

    @Environment(\.colorScheme) private var colorScheme

    public init(model: WarrenDesktopGitPanelModel) {
        self.model = model
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            header(tokens: tokens)
            if model.fileDiff.loading {
                emptyState("Loading diff…", tokens: tokens)
            } else if let error = model.fileDiff.errorMessage {
                emptyState(error, tokens: tokens, isError: true)
            } else {
                tabs(tokens: tokens)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File diff")
    }

    private func header(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            Text(model.fileView?.path ?? "")
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("File \(model.fileView?.path ?? "")")
            if model.fileView?.staged == true {
                Text("staged")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, WarrenSpacing.compact)
                    .background(tokens.tertiaryWash)
                    .clipShape(.rect(cornerRadius: WarrenRadius.xs))
            }
            if let commit = model.fileView?.commit {
                Text(commit)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
            }
            Spacer(minLength: 0)
            Button(action: model.closeFileView) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .frame(
                width: WarrenLayoutMetrics.compactControlHeight,
                height: WarrenLayoutMetrics.compactControlHeight
            )
            .contentShape(.rect)
            .foregroundStyle(tokens.mutedForeground)
            .help("Close file diff")
            .accessibilityLabel("Close file diff")
        }
        .padding(.horizontal, WarrenSpacing.large)
        .padding(.vertical, WarrenSpacing.compact)
        .background(tokens.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
        }
    }

    private func tabs(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: WarrenSpacing.xxs) {
                WarrenGitDiffTab(
                    title: "Diff",
                    isSelected: model.diffViewTab == .diff,
                    tokens: tokens,
                    action: { model.diffViewTab = .diff }
                )
                WarrenGitDiffTab(
                    title: "File",
                    isSelected: model.diffViewTab == .file,
                    tokens: tokens,
                    action: { model.diffViewTab = .file }
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.large)
            .padding(.top, WarrenSpacing.xs)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tokens.border)
                    .frame(height: WarrenSpacing.hairline)
            }

            if model.diffViewTab == .diff {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: WarrenSpacing.medium) {
                        WarrenGitDiffStyleButton(
                            title: "Highlight",
                            isSelected: model.diffStyle == .split,
                            tokens: tokens,
                            action: { model.diffStyle = .split }
                        )
                        WarrenGitDiffStyleButton(
                            title: "Unified",
                            isSelected: model.diffStyle == .unified,
                            tokens: tokens,
                            action: { model.diffStyle = .unified }
                        )
                    }
                    .padding(.horizontal, WarrenSpacing.large)
                    .padding(.top, WarrenSpacing.medium)

                    Group {
                        if model.diffStyle == .unified {
                            WarrenGitUnifiedDiffView(
                                diff: model.fileDiff.diff,
                                path: model.fileView?.path ?? ""
                            )
                        } else {
                            WarrenGitSplitDiffView(
                                diff: model.fileDiff.diff,
                                path: model.fileView?.path ?? ""
                            )
                        }
                    }
                    .padding(.horizontal, WarrenSpacing.large)
                    .padding(.vertical, WarrenSpacing.medium)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                WarrenGitFileContentView(
                    content: model.fileDiff.content,
                    path: model.fileView?.path ?? ""
                )
                .padding(.horizontal, WarrenSpacing.large)
                .padding(.vertical, WarrenSpacing.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ message: String, tokens: WarrenColorTokens, isError: Bool = false) -> some View {
        Text(message)
            .font(WarrenTypography.supporting)
            .foregroundStyle(isError ? tokens.destructive : tokens.mutedForeground)
            .padding(WarrenSpacing.large)
            .background(isError ? tokens.destructive.opacity(0.08) : .clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private struct WarrenGitDiffTab: View {
    let title: String
    let isSelected: Bool
    let tokens: WarrenColorTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                .padding(.horizontal, WarrenSpacing.medium)
                .padding(.vertical, WarrenSpacing.xs)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? tokens.highlight : .clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct WarrenGitDiffStyleButton: View {
    let title: String
    let isSelected: Bool
    let tokens: WarrenColorTokens
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? tokens.highlight : tokens.mutedForeground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) diff layout")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Diff renderers

private struct WarrenGitUnifiedDiffView: View {
    let diff: String
    let path: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let lines = WarrenDesktopGitDiffParser.parse(diff).filter { $0.kind != .meta }
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 0) {
                                lineNumber(line.oldLine, tokens: tokens)
                                lineNumber(line.newLine, tokens: tokens)
                                indicator(for: line.kind, tokens: tokens)
                                WarrenGitCodeLineView(
                                    text: line.text.isEmpty ? " " : line.text,
                                    path: path,
                                    colorScheme: colorScheme,
                                    baseColor: foreground(for: line.kind, tokens: tokens),
                                    highlightsSyntax: line.kind != .hunk
                                )
                                    .textSelection(.enabled)
                            }
                            .frame(minWidth: proxy.size.width, minHeight: WarrenGitDiffMetrics.lineHeight, alignment: .leading)
                            .background(background(for: line.kind, tokens: tokens))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                .padding(.vertical, WarrenSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func lineNumber(_ number: Int?, tokens: WarrenColorTokens) -> some View {
        Text(number.map(String.init) ?? "")
            .font(WarrenGitDiffMetrics.lineNumberFont)
            .foregroundStyle(tokens.mutedForeground.opacity(0.7))
            .frame(width: WarrenGitDiffMetrics.lineNumberWidth, alignment: .trailing)
            .padding(.trailing, WarrenSpacing.xs)
            .accessibilityHidden(true)
    }

    private func indicator(for kind: WarrenDesktopGitDiffLineKind, tokens: WarrenColorTokens) -> some View {
        let value: String
        let color: Color
        switch kind {
        case .add:
            value = "+"
            color = tokens.success
        case .del:
            value = "-"
            color = tokens.destructive
        case .hunk, .meta, .context:
            value = ""
            color = tokens.mutedForeground
        }
        return Text(value)
            .font(WarrenGitDiffMetrics.codeFont)
            .foregroundStyle(color)
            .frame(width: WarrenGitDiffMetrics.indicatorWidth)
            .accessibilityHidden(true)
    }

    private func foreground(for kind: WarrenDesktopGitDiffLineKind, tokens: WarrenColorTokens) -> Color {
        switch kind {
        case .add, .del, .context: tokens.foreground
        case .hunk: tokens.info
        case .meta: tokens.mutedForeground
        }
    }

    private func background(for kind: WarrenDesktopGitDiffLineKind, tokens: WarrenColorTokens) -> Color {
        switch kind {
        case .add: tokens.success.opacity(0.12)
        case .del: tokens.destructive.opacity(0.12)
        case .hunk: tokens.info.opacity(0.10)
        case .meta, .context: .clear
        }
    }
}

private struct WarrenGitSplitDiffView: View {
    let diff: String
    let path: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let rows = WarrenGitSplitRow.make(from: WarrenDesktopGitDiffParser.parse(diff))
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            if let fullWidth = row.fullWidth {
                                fullWidthRow(fullWidth, tokens: tokens, viewportWidth: proxy.size.width)
                            } else {
                                HStack(spacing: 0) {
                                    side(
                                        line: row.old,
                                        tokens: tokens,
                                        isOld: true,
                                        minimumWidth: (proxy.size.width - WarrenSpacing.hairline) / 2,
                                        path: path,
                                        colorScheme: colorScheme
                                    )
                                    Rectangle()
                                        .fill(tokens.border)
                                        .frame(width: WarrenSpacing.hairline)
                                    side(
                                        line: row.new,
                                        tokens: tokens,
                                        isOld: false,
                                        minimumWidth: (proxy.size.width - WarrenSpacing.hairline) / 2,
                                        path: path,
                                        colorScheme: colorScheme
                                    )
                                }
                                .frame(minWidth: proxy.size.width, minHeight: WarrenGitDiffMetrics.lineHeight, alignment: .leading)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                .padding(.vertical, WarrenSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func side(
        line: WarrenDesktopGitDiffLine?,
        tokens: WarrenColorTokens,
        isOld: Bool,
        minimumWidth: CGFloat,
        path: String,
        colorScheme: ColorScheme
    ) -> some View {
        HStack(spacing: 0) {
            Text(lineNumber(for: line, isOld: isOld))
                .font(WarrenGitDiffMetrics.lineNumberFont)
                .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                .frame(width: WarrenGitDiffMetrics.lineNumberWidth, alignment: .trailing)
                .padding(.trailing, WarrenSpacing.xs)
                .accessibilityHidden(true)
            Text(indicator(for: line, isOld: isOld))
                .font(WarrenGitDiffMetrics.codeFont)
                .foregroundStyle(indicatorColor(for: line, tokens: tokens))
                .frame(width: WarrenGitDiffMetrics.indicatorWidth)
                .accessibilityHidden(true)
            WarrenGitCodeLineView(
                text: line?.text.isEmpty == false ? line?.text ?? "" : " ",
                path: path,
                colorScheme: colorScheme,
                baseColor: tokens.foreground,
                highlightsSyntax: true
            )
                .textSelection(.enabled)
        }
        .frame(minWidth: minimumWidth, minHeight: WarrenGitDiffMetrics.lineHeight, alignment: .leading)
        .background(sideBackground(for: line, tokens: tokens, isOld: isOld))
    }

    private func fullWidthRow(
        _ line: WarrenDesktopGitDiffLine,
        tokens: WarrenColorTokens,
        viewportWidth: CGFloat
    ) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(WarrenGitDiffMetrics.codeFont)
            .foregroundStyle(line.kind == .hunk ? tokens.info : tokens.mutedForeground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, WarrenGitDiffMetrics.lineNumberWidth + WarrenGitDiffMetrics.indicatorWidth)
            .padding(.trailing, WarrenSpacing.compact)
            .frame(minWidth: viewportWidth, minHeight: WarrenGitDiffMetrics.lineHeight, alignment: .leading)
            .background(line.kind == .hunk ? tokens.info.opacity(0.10) : tokens.muted.opacity(0.4))
            .textSelection(.enabled)
    }

    private func lineNumber(for line: WarrenDesktopGitDiffLine?, isOld: Bool) -> String {
        let number = isOld ? line?.oldLine : line?.newLine
        return number.map(String.init) ?? ""
    }

    private func indicator(for line: WarrenDesktopGitDiffLine?, isOld: Bool) -> String {
        guard let line else { return "" }
        if isOld, line.kind == .del { return "-" }
        if !isOld, line.kind == .add { return "+" }
        return ""
    }

    private func indicatorColor(for line: WarrenDesktopGitDiffLine?, tokens: WarrenColorTokens) -> Color {
        switch line?.kind {
        case .add: tokens.success
        case .del: tokens.destructive
        default: tokens.mutedForeground
        }
    }

    private func sideBackground(
        for line: WarrenDesktopGitDiffLine?,
        tokens: WarrenColorTokens,
        isOld: Bool
    ) -> Color {
        if isOld, line?.kind == .del {
            return tokens.destructive.opacity(0.12)
        }
        if !isOld, line?.kind == .add {
            return tokens.success.opacity(0.12)
        }
        return .clear
    }
}

struct WarrenGitSplitRow {
    let old: WarrenDesktopGitDiffLine?
    let new: WarrenDesktopGitDiffLine?
    let fullWidth: WarrenDesktopGitDiffLine?

    static func make(from lines: [WarrenDesktopGitDiffLine]) -> [Self] {
        let visibleLines = lines.filter { $0.kind != .meta }
        var rows: [Self] = []
        var index = 0
        while index < visibleLines.count {
            let line = visibleLines[index]
            if line.kind == .del {
                var deletions: [WarrenDesktopGitDiffLine] = []
                var additions: [WarrenDesktopGitDiffLine] = []
                while index < visibleLines.count, visibleLines[index].kind == .del {
                    deletions.append(visibleLines[index])
                    index += 1
                }
                while index < visibleLines.count, visibleLines[index].kind == .add {
                    additions.append(visibleLines[index])
                    index += 1
                }
                for offset in 0..<max(deletions.count, additions.count) {
                    rows.append(Self(
                        old: offset < deletions.count ? deletions[offset] : nil,
                        new: offset < additions.count ? additions[offset] : nil,
                        fullWidth: nil
                    ))
                }
                continue
            }
            if line.kind == .add {
                rows.append(Self(old: nil, new: line, fullWidth: nil))
            } else if line.kind == .hunk || line.kind == .meta {
                rows.append(Self(old: nil, new: nil, fullWidth: line))
            } else {
                rows.append(Self(old: line, new: line, fullWidth: nil))
            }
            index += 1
        }
        return rows
    }
}

private struct WarrenGitCodeLineView: View {
    let text: String
    let path: String
    let colorScheme: ColorScheme
    let baseColor: Color
    let highlightsSyntax: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let code = highlightsSyntax
            ? WarrenGitSyntaxHighlighter.text(text, path: path, tokens: tokens, baseColor: baseColor)
            : Text(text).foregroundColor(baseColor)
        code
            .font(WarrenGitDiffMetrics.codeFont)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, WarrenSpacing.compact)
    }
}

private enum WarrenGitSyntaxHighlighter {
    private struct Segment {
        let text: String
        let color: Color
    }

    static func text(
        _ source: String,
        path: String,
        tokens: WarrenColorTokens,
        baseColor: Color
    ) -> Text {
        let segments = tokenize(source, path: path, tokens: tokens, baseColor: baseColor)
        return segments.reduce(Text("") ) { result, segment in
            result + Text(segment.text).foregroundColor(segment.color)
        }
    }

    private static func tokenize(
        _ source: String,
        path: String,
        tokens: WarrenColorTokens,
        baseColor: Color
    ) -> [Segment] {
        let keywords: Set<String> = [
            "actor", "async", "await", "break", "case", "catch", "class", "convenience",
            "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
            "fallthrough", "final", "for", "func", "guard", "if", "import", "in", "init",
            "let", "nonisolated", "operator", "private", "protocol", "public", "repeat",
            "return", "struct", "subscript", "switch", "throw", "throws", "try", "typealias",
            "var", "where", "while", "with", "from", "as", "and", "def", "elif", "except",
            "finally", "global", "lambda", "pass", "raise", "yield", "const", "function",
            "interface", "namespace", "new", "null", "of", "this", "typeof", "undefined",
            "export", "implements", "package", "super", "true", "false", "nil", "None",
        ]
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        let hashComments = ["py", "rb", "sh", "bash", "zsh", "yaml", "yml", "toml", "ini", "dockerfile"].contains(fileExtension)
        let characters = Array(source)
        var segments: [Segment] = []
        var plain = ""
        var index = 0

        func flushPlain() {
            guard !plain.isEmpty else { return }
            segments.append(Segment(text: plain, color: baseColor))
            plain.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]
            if (character == "/" && index + 1 < characters.count && characters[index + 1] == "/")
                || (hashComments && character == "#") {
                flushPlain()
                segments.append(Segment(text: String(characters[index...]), color: tokens.mutedForeground.opacity(0.78)))
                break
            }
            if character == "\"" || character == "'" || character == "`" {
                flushPlain()
                let quote = character
                var end = index + 1
                var escaped = false
                while end < characters.count {
                    let next = characters[end]
                    if escaped {
                        escaped = false
                    } else if next == "\\" {
                        escaped = true
                    } else if next == quote {
                        end += 1
                        break
                    }
                    end += 1
                }
                segments.append(Segment(text: String(characters[index..<min(end, characters.count)]), color: tokens.success))
                index = end
                continue
            }
            if character.isNumber {
                flushPlain()
                var end = index + 1
                while end < characters.count, characters[end].isNumber || characters[end] == "." {
                    end += 1
                }
                segments.append(Segment(text: String(characters[index..<end]), color: tokens.warning))
                index = end
                continue
            }
            if character.isLetter || character == "_" {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                    end += 1
                }
                let word = String(characters[index..<end])
                if keywords.contains(word) {
                    flushPlain()
                    segments.append(Segment(text: word, color: tokens.info))
                } else if word.first?.isUppercase == true {
                    flushPlain()
                    segments.append(Segment(text: word, color: tokens.highlight))
                } else {
                    plain.append(contentsOf: word)
                }
                index = end
                continue
            }
            plain.append(character)
            index += 1
        }
        flushPlain()
        return segments
    }
}

private struct WarrenGitFileContentView: View {
    let content: String
    let path: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let lines = content.components(separatedBy: "\n")
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(spacing: 0) {
                                Text("\(index + 1)")
                                    .font(WarrenGitDiffMetrics.lineNumberFont)
                                    .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                                    .frame(width: WarrenGitDiffMetrics.lineNumberWidth, alignment: .trailing)
                                    .padding(.trailing, WarrenSpacing.xs)
                                    .accessibilityHidden(true)
                                WarrenGitCodeLineView(
                                    text: line.isEmpty ? " " : line,
                                    path: path,
                                    colorScheme: colorScheme,
                                    baseColor: tokens.foreground,
                                    highlightsSyntax: true
                                )
                                    .textSelection(.enabled)
                            }
                            .frame(minWidth: proxy.size.width, minHeight: WarrenGitDiffMetrics.lineHeight, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                .padding(.vertical, WarrenSpacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
