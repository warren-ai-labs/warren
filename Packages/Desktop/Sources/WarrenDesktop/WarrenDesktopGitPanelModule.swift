import SwiftUI

@MainActor
public final class WarrenDesktopGitPanelModule {
    public static let panelID = "git"

    public let model: WarrenDesktopGitPanelModel

    public init(model: WarrenDesktopGitPanelModel) {
        self.model = model
    }

    public lazy var contribution = WarrenDesktopPanelContribution(
        descriptor: .init(id: Self.panelID, title: "Git", systemImage: "arrow.triangle.branch"),
        availability: { $0.workspaceID != nil },
        activate: { [weak model] context in
            guard let workspaceID = context.workspaceID else { return }
            model?.activate(workspaceID: workspaceID)
        },
        deactivate: { [weak model] in model?.deactivate() },
        refresh: { [weak model] in model?.refresh() },
        closeDetail: { [weak model] in model?.closeFileView() },
        rightContent: { [weak model] context in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(WarrenDesktopGitPanelView(
                workspaceName: context.workspaceName,
                model: model,
                onClose: {}
            ))
        },
        rightContentWithClose: { [weak model] context, onClose in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(WarrenDesktopGitPanelView(
                workspaceName: context.workspaceName,
                model: model,
                onClose: { onClose.call() }
            ))
        },
        centerDetail: { [weak model] _ in
            guard let model, model.fileView != nil else { return nil }
            return AnyView(WarrenDesktopGitDiffView(model: model))
        },
        connectionGenerationWillChange: { [weak model] endpointID, generation in
            model?.connectionWillChange(endpointID: endpointID, generation: generation)
        }
    )
}
