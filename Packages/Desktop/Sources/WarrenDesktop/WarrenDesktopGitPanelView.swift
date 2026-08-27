import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenObservation

// MARK: - Panel

/// Right-side Git panel mirroring the web client's `GitPanel` layout: a fixed
/// Branch section followed by collapsible Checkout, Pull Request, Changes and
/// History panes.
public struct WarrenDesktopGitPanelView: View {
    let workspaceName: String
    @Bindable var model: WarrenDesktopGitPanelModel
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
        .frame(width: WarrenLayoutMetrics.gitPanelDefaultWidth)
        .background(tokens.background)
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
            Text(workspaceName.isEmpty ? "Git" : workspaceName)
                .font(WarrenTypography.paneHeader)
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
            .frame(width: 22, height: 22)
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
        .padding(.horizontal, WarrenSpacing.medium)
        .frame(height: WarrenLayoutMetrics.paneHeaderHeight)
        .background(tokens.chromeSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
        }
    }

    private func errorBanner(_ error: String, tokens: WarrenColorTokens) -> some View {
        Text(error)
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.destructive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WarrenSpacing.medium)
            .padding(.vertical, WarrenSpacing.small)
            .background(tokens.destructive.opacity(0.08))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tokens.border)
                    .frame(height: WarrenSpacing.hairline)
            }
            .accessibilityLabel("Git error: \(error)")
    }

    private func content(tokens: WarrenColorTokens) -> some View {
        Group {
            if model.showsLoading {
                loadingState(tokens: tokens)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        WarrenGitBranchSection(model: model)
                        WarrenGitPaneHeader(
                            title: "Checkout",
                            isOpen: model.openPanes.contains(.checkout),
                            onToggle: { model.togglePane(.checkout) }
                        )
                        if model.openPanes.contains(.checkout) {
                            WarrenGitCheckoutPane(model: model)
                        }
                        if model.panel?.remote != nil {
                            WarrenGitPaneHeader(
                                title: "Pull Request",
                                isOpen: model.openPanes.contains(.pr),
                                onToggle: { model.togglePane(.pr) }
                            )
                            if model.openPanes.contains(.pr) {
                                WarrenGitPullRequestPane(model: model)
                            }
                        }
                        WarrenGitPaneHeader(
                            title: model.changeCount > 0 ? "Changes (\(model.changeCount))" : "Changes",
                            isOpen: model.openPanes.contains(.changes),
                            onToggle: { model.togglePane(.changes) }
                        )
                        if model.openPanes.contains(.changes) {
                            WarrenGitChangesPane(model: model)
                        }
                        WarrenGitPaneHeader(
                            title: historyTitle,
                            isOpen: model.openPanes.contains(.history),
                            onToggle: { model.togglePane(.history) }
                        )
                        if model.openPanes.contains(.history) {
                            WarrenGitHistoryPane(model: model)
                        }
                    }
                    .padding(.vertical, WarrenSpacing.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyTitle: String {
        guard let panel = model.panel,
              panel.mainBranch != nil,
              !panel.merged,
              panel.operation == nil else { return "History" }
        return "History · not in \(panel.mainBranch ?? "")"
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
    @Bindable var model: WarrenDesktopGitPanelModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            Text("Branch")
                .font(WarrenTypography.sectionLabel)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityAddTraits(.isHeader)

            if let operation = model.panel?.operation, !operation.isEmpty {
                Text("\(model.operationLabel) in progress — resolve it before pushing or pulling")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(model.operationLabel) in progress")
            }

            HStack(spacing: WarrenSpacing.xs) {
                let branch = model.panel?.branch ?? ""
                Text(branch.isEmpty ? "—" : branch)
                    .font(WarrenTypography.navigationItem)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let upstream = model.panel?.upstream, !upstream.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .accessibilityHidden(true)
                    Text(upstream)
                        .font(WarrenTypography.navigationMeta)
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

            HStack(spacing: WarrenSpacing.small) {
                WarrenGitActionButton(
                    label: "Refresh",
                    isBusy: false,
                    disabled: model.busy,
                    action: model.refresh
                )
                WarrenGitActionButton(
                    label: model.activeAction == .pull ? "Pulling…" : "Pull",
                    isBusy: model.activeAction == .pull,
                    disabled: model.busy || model.panel == nil,
                    action: model.pull
                )
                WarrenGitActionButton(
                    label: model.activeAction == .push ? "Pushing…" : "Push",
                    isBusy: model.activeAction == .push,
                    disabled: model.busy || model.panel == nil,
                    action: pushOrCommit
                )
            }

            if model.commitOpen {
                commitBox(tokens: tokens)
            }
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.small)
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
    @Bindable var model: WarrenDesktopGitPanelModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            Picker("Branch", selection: $model.branchSelection) {
                Text("Choose a branch…").tag("")
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
            .disabled(model.createBranchMode || model.localBranches().isEmpty && model.remoteBranches().isEmpty)

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
            }

            HStack(spacing: WarrenSpacing.small) {
                WarrenGitActionButton(
                    label: model.activeAction == .checkout
                        ? "Switching…"
                        : (model.createBranchMode ? "Create" : "Checkout"),
                    isBusy: model.activeAction == .checkout,
                    disabled: model.busy || (model.createBranchMode
                        ? model.newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        : model.branchSelection.isEmpty),
                    action: submitCheckout
                )
                WarrenGitActionButton(
                    label: model.createBranchMode ? "Existing" : "New",
                    isBusy: false,
                    disabled: model.busy,
                    action: model.toggleCreateMode
                )
            }
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.bottom, WarrenSpacing.medium)
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
    @Bindable var model: WarrenDesktopGitPanelModel

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
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.bottom, WarrenSpacing.medium)
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
                if let number = pr.number {
                    Text("#\(number)")
                        .font(WarrenTypography.paneHeader)
                }
                if !stateLabel.isEmpty {
                    Text(stateLabel)
                        .font(WarrenTypography.badge)
                        .foregroundStyle(stateColor)
                        .padding(.horizontal, WarrenSpacing.xs)
                        .padding(.vertical, 2)
                        .background(stateColor.opacity(0.12))
                        .clipShape(.rect(cornerRadius: WarrenRadius.small))
                }
                if pr.draft {
                    Text("Draft")
                        .font(WarrenTypography.badge)
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, WarrenSpacing.xs)
                        .padding(.vertical, 2)
                        .background(tokens.muted)
                        .clipShape(.rect(cornerRadius: WarrenRadius.small))
                }
            }
            Text(pr.title)
                .font(WarrenTypography.navigationItem)
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
                    .foregroundStyle(tokens.mutedForeground)
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
                .help("Open \(urlString)")
                .accessibilityLabel("Open pull request \(urlString)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WarrenSpacing.small)
        .background(tokens.muted.opacity(0.5))
        .clipShape(.rect(cornerRadius: WarrenRadius.medium))
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
    @Bindable var model: WarrenDesktopGitPanelModel

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
                        .font(WarrenTypography.sectionLabel)
                        .foregroundStyle(tokens.mutedForeground)
                    WarrenGitDiffCounts(added: summary.added, deleted: summary.deleted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WarrenSpacing.medium)
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
                    .padding(.horizontal, WarrenSpacing.medium)
                    .padding(.vertical, WarrenSpacing.small)
            }
        }
        .padding(.bottom, WarrenSpacing.medium)
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
                    .frame(width: 16, alignment: .center)
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
            .padding(.horizontal, WarrenSpacing.medium)
            .padding(.vertical, 3)
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
        case "A": tokens.success
        case "U": tokens.warning
        default: tokens.info
        }
    }
}

// MARK: - History pane

private struct WarrenGitHistoryPane: View {
    @Bindable var model: WarrenDesktopGitPanelModel

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
                    .padding(.horizontal, WarrenSpacing.medium)
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
        .padding(.bottom, WarrenSpacing.medium)
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
                HStack(spacing: WarrenSpacing.small) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(commit.subject)
                            .font(WarrenTypography.supporting)
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: WarrenSpacing.xs) {
                            Text(commit.short)
                                .font(.system(size: 10, design: .monospaced))
                            Text("·")
                            Text(commit.author)
                            Text("·")
                            Text(WarrenDesktopGitRelativeTime.string(from: commit.time))
                            let summary = WarrenDesktopGitDiffSummary.summary(of: commit.files)
                            if summary.added > 0 || summary.deleted > 0 {
                                Text("·")
                                WarrenGitDiffCounts(added: summary.added, deleted: summary.deleted)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WarrenSpacing.medium)
                .padding(.vertical, 4)
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
                .padding(.leading, WarrenSpacing.medium)
            }
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
    let isOpen: Bool
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: onToggle) {
            HStack(spacing: WarrenSpacing.small) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 10)
                    .accessibilityHidden(true)
                Text(title)
                    .font(WarrenTypography.paneHeader)
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.medium)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background(hovered ? tokens.fillHover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(title) panel")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }
}

private struct WarrenGitActionButton: View {
    let label: String
    let isBusy: Bool
    let disabled: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button(action: action) {
            HStack(spacing: WarrenSpacing.xs) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .lineLimit(1)
            }
        }
        .buttonStyle(WarrenGitActionButtonStyle(tokens: tokens))
        .disabled(disabled)
        .help(label)
    }
}

private struct WarrenGitActionButtonStyle: ButtonStyle {
    let tokens: WarrenColorTokens

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WarrenTypography.chromeLabel)
            .padding(.horizontal, WarrenSpacing.small + 2)
            .padding(.vertical, 3)
            .background(configuration.isPressed ? tokens.fillSelected : tokens.muted)
            .clipShape(.rect(cornerRadius: WarrenRadius.small))
            .foregroundStyle(tokens.foreground)
            .opacity(isEnabled ? 1 : 0.42)
    }
}

// MARK: - File diff viewer

/// Full-area file diff viewer, replicating the web client's `FileDiffView`.
/// The terminal stays mounted underneath; the composition root overlays this
/// view while a file is selected.
public struct WarrenDesktopGitDiffView: View {
    @Bindable var model: WarrenDesktopGitPanelModel

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
                    .font(WarrenTypography.badge)
                    .foregroundStyle(tokens.info)
                    .padding(.horizontal, WarrenSpacing.xs)
                    .padding(.vertical, 2)
                    .background(tokens.info.opacity(0.12))
                    .clipShape(.rect(cornerRadius: WarrenRadius.small))
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
            .frame(width: 22, height: 22)
            .contentShape(.rect)
            .foregroundStyle(tokens.mutedForeground)
            .help("Close file diff")
            .accessibilityLabel("Close file diff")
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .frame(height: WarrenLayoutMetrics.paneHeaderHeight)
        .background(tokens.chromeSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)
        }
    }

    private func tabs(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: WarrenSpacing.small) {
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
                if model.diffViewTab == .diff {
                    HStack(spacing: 2) {
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
                    .padding(2)
                    .background(tokens.muted)
                    .clipShape(.rect(cornerRadius: WarrenRadius.small))
                }
            }
            .padding(.horizontal, WarrenSpacing.medium)
            .frame(height: 32)

            Group {
                if model.diffViewTab == .diff {
                    if model.diffStyle == .unified {
                        WarrenGitUnifiedDiffView(diff: model.fileDiff.diff)
                    } else {
                        WarrenGitSplitDiffView(diff: model.fileDiff.diff)
                    }
                } else {
                    WarrenGitFileContentView(content: model.fileDiff.content)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ message: String, tokens: WarrenColorTokens, isError: Bool = false) -> some View {
        VStack(spacing: WarrenSpacing.standard) {
            if !isError {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(message)
                .font(WarrenTypography.supporting)
                .foregroundStyle(isError ? tokens.destructive : tokens.mutedForeground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, WarrenSpacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .font(WarrenTypography.chromeLabel)
                .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                .padding(.horizontal, WarrenSpacing.small + 2)
                .padding(.vertical, 3)
                .background(isSelected ? tokens.muted : .clear)
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
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
                .font(WarrenTypography.chromeLabel)
                .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                .padding(.horizontal, WarrenSpacing.small)
                .padding(.vertical, 2)
                .background(isSelected ? tokens.ring : .clear)
                .clipShape(.rect(cornerRadius: WarrenRadius.small - 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) diff layout")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Diff renderers

private struct WarrenGitUnifiedDiffView: View {
    let diff: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let lines = WarrenDesktopGitDiffParser.parse(diff)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        lineNumber(line.oldLine, tokens: tokens, width: 40)
                        lineNumber(line.newLine, tokens: tokens, width: 40)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(foreground(for: line.kind, tokens: tokens))
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    .background(background(for: line.kind, tokens: tokens))
                }
            }
            .padding(.vertical, WarrenSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func lineNumber(_ number: Int?, tokens: WarrenColorTokens, width: CGFloat) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(tokens.mutedForeground.opacity(0.7))
            .frame(width: width, alignment: .trailing)
            .padding(.horizontal, WarrenSpacing.xs)
            .accessibilityHidden(true)
    }

    private func foreground(for kind: WarrenDesktopGitDiffLineKind, tokens: WarrenColorTokens) -> Color {
        switch kind {
        case .add: tokens.success
        case .del: tokens.destructive
        case .hunk: tokens.info
        case .meta: tokens.mutedForeground
        case .context: tokens.foreground
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let lines = WarrenDesktopGitDiffParser.parse(diff)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        side(
                            number: line.kind == .del || line.kind == .context ? line.oldLine : nil,
                            text: line.kind == .add ? "" : line.text,
                            kind: line.kind,
                            tokens: tokens,
                            isOld: true
                        )
                        side(
                            number: line.kind == .add || line.kind == .context ? line.newLine : nil,
                            text: line.kind == .del ? "" : line.text,
                            kind: line.kind,
                            tokens: tokens,
                            isOld: false
                        )
                    }
                    .background(splitBackground(for: line.kind, tokens: tokens))
                }
            }
            .padding(.vertical, WarrenSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func side(
        number: Int?,
        text: String,
        kind: WarrenDesktopGitDiffLineKind,
        tokens: WarrenColorTokens,
        isOld: Bool
    ) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                .frame(width: 40, alignment: .trailing)
                .padding(.horizontal, WarrenSpacing.xs)
                .accessibilityHidden(true)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(splitForeground(for: kind, tokens: tokens))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isOld ? tokens.destructive.opacity(0.06) : tokens.success.opacity(0.06), ignoresSafeAreaEdges: [])
    }

    private func splitForeground(for kind: WarrenDesktopGitDiffLineKind, tokens: WarrenColorTokens) -> Color {
        switch kind {
        case .add: tokens.success
        case .del: tokens.destructive
        case .hunk: tokens.info
        case .meta: tokens.mutedForeground
        case .context: tokens.foreground
        }
    }

    private func splitBackground(for kind: WarrenDesktopGitDiffLineKind, tokens: WarrenColorTokens) -> Color {
        switch kind {
        case .hunk: tokens.info.opacity(0.10)
        case .meta: tokens.muted.opacity(0.4)
        default: .clear
        }
    }
}

private struct WarrenGitFileContentView: View {
    let content: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let lines = content.components(separatedBy: "\n")
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 0) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                            .frame(width: 44, alignment: .trailing)
                            .padding(.horizontal, WarrenSpacing.xs)
                            .accessibilityHidden(true)
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, WarrenSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
