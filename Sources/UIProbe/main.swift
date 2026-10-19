import AppKit
import WarrenDesktop
import WarrenObservation
import Foundation
import SwiftUI

private struct UIProbeReport: Codable {
    let width: Int
    let height: Int
    let interactionBefore: WarrenInteractionSnapshot
    let interactionAfter: WarrenInteractionSnapshot
    let semanticNodeCount: Int
    let observedActions: [String]
    let invariantViolations: [String]
}

private enum UIProbeError: Error, CustomStringConvertible {
    case noSemanticNodes

    var description: String {
        switch self {
        case .noSemanticNodes:
            "The real desktop view emitted no semantic UI nodes."
        }
    }
}

private struct ProbeTerminalSurface: View {
    let context: WarrenDesktopTerminalContext

    var body: some View {
        Text("probe:\(context.tab.id)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .foregroundStyle(Color.green)
            .font(.system(size: 12, design: .monospaced))
            .warrenSemanticElement(
                id: "terminal.\(context.tab.id)",
                role: .terminal,
                label: "Terminal \(context.tab.title)"
            )
    }
}

/// A non-visual, non-activating UI observer.
///
/// It mounts the production SwiftUI tree in an in-process hosting view, reads
/// the semantic contract emitted by that tree, and verifies that neither the
/// user's frontmost application nor the global mouse position changed. It
/// never creates a bitmap, screenshot, CGEvent, or key window.
@MainActor
private enum UIProbe {
    static func run() throws {
        let width: CGFloat = 1_280
        let height: CGFloat = 800
        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["WARREN_ARTIFACT_DIR"]
                ?? "/tmp/warren-observation/ui-probe",
            isDirectory: true
        )
        let recorder = WarrenSemanticRecorder()
        let before = WarrenInteractionGuard.capture()
        var actions: [WarrenDesktopAction] = []

        let root = WarrenDesktopRoot(
            projection: WarrenDesktopFixture.preview.projection,
            actions: WarrenDesktopActions { actions.append($0) },
            persistenceEnabled: false
        ) { context in
            ProbeTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .environment(\.warrenForceHover, true)
        .environment(\.warrenSemanticRecorder, recorder)
        .frame(width: width, height: height)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()

        let initialWorkspace = WarrenDesktopFixture.preview.projection.groups[0].workspaces[0]
        let initialProject = WarrenDesktopFixture.preview.projection.groups[0].project
        let initialSnapshot = recorder.snapshot()
        guard !initialSnapshot.nodes.isEmpty else { throw UIProbeError.noSemanticNodes }
        // Every row starts open; only the user folds one away.
        guard initialSnapshot.nodes.first(where: {
            $0.id == "project.\(initialProject.id.description)"
        })?.value == "Expanded" else {
            throw NSError(
                domain: "Warren.UIProbe",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Project rows must be expanded initially."]
            )
        }
        try recorder.perform(
            .press,
            on: "workspace.project-list.\(initialWorkspace.id.description)"
        )
        try recorder.perform(
            .press,
            on: "project.\(initialProject.id.description).new-workspace"
        )
        let snapshot = recorder.snapshot()

        let after = WarrenInteractionGuard.capture()
        var violations: [String] = []
        do {
            try WarrenInteractionGuard.verifyUnchanged(from: before, to: after)
        } catch {
            violations.append(String(describing: error))
        }
        let duplicateIDs = Dictionary(grouping: snapshot.nodes, by: \.id)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        if !duplicateIDs.isEmpty {
            violations.append("Duplicate semantic IDs: \(duplicateIDs.joined(separator: ", "))")
        }
        let invalidFrames = snapshot.nodes.filter {
            $0.frame.width <= 0 || $0.frame.height <= 0
        }.map(\.id)
        if !invalidFrames.isEmpty {
            violations.append("Non-positive semantic frames: \(invalidFrames.joined(separator: ", "))")
        }
        // A sidebar row draws its controls inside the same band, so the row's
        // navigation target ends where the first control begins. A target that
        // stops earlier leaves a strip that looks like part of the row and does
        // nothing, which a probe that only asks whether a target exists cannot
        // see. The allowance is the spacing the tree separates one row's
        // elements by; anything wider is an unhandled band.
        let rowElementSpacing: CGFloat = 8
        // The smallest row the tree draws. A navigation target under this is a
        // sliver however wide it is.
        let minimumRowTargetHeight: CGFloat = 22
        let sidebarRowPrefixes = [
            "project.",
            "workspace.project-list.",
            "workspace-session.project-list.",
        ]
        let allIDs = Set(snapshot.nodes.map(\.id))
        let sidebarRows = snapshot.nodes.filter { node in
            guard sidebarRowPrefixes.contains(where: { node.id.hasPrefix($0) }) else { return false }
            // A control inside a row carries the row's id as its prefix; only
            // the row itself is a row.
            return !allIDs.contains { other in
                other != node.id && node.id.hasPrefix(other + ".")
            }
        }
        let sliverTargets = sidebarRows
            .filter { $0.frame.height < minimumRowTargetHeight }
            .map(\.id)
        if !sliverTargets.isEmpty {
            violations.append(
                "Sidebar navigation targets are too small to hit: " +
                    sliverTargets.sorted().joined(separator: ", ")
            )
        }
        // The sidebar's own column, so a window-wide surface that happens to be
        // centred in a row's band — the terminal — is not read as one of the
        // row's controls.
        let sidebarColumn = sidebarRows.map(\.frame.x).min().map { minX in
            let maxX = sidebarRows.map { $0.frame.x + $0.frame.width }.max() ?? minX
            return minX ..< maxX
        }
        var unhandledRowBands: [String] = []
        for row in sidebarRows {
            let trailingEdge = row.frame.x + row.frame.width
            let band = row.frame.y ..< (row.frame.y + row.frame.height)
            let controls = snapshot.nodes
                .filter { $0.id != row.id }
                .filter { node in
                    let center = node.frame.y + node.frame.height / 2
                    return band.contains(center)
                        && node.frame.x >= trailingEdge
                        && (sidebarColumn?.contains(node.frame.x) ?? true)
                }
                .sorted { $0.frame.x < $1.frame.x }
            var previous = trailingEdge
            for control in controls {
                if control.frame.x - previous > rowElementSpacing {
                    unhandledRowBands.append(row.id)
                    break
                }
                previous = control.frame.x + control.frame.width
            }
        }
        if !unhandledRowBands.isEmpty {
            violations.append(
                "Sidebar navigation targets leave part of their row unhandled: " +
                    unhandledRowBands.sorted().joined(separator: ", ")
            )
        }

        try WarrenArtifactWriter.writeJSON(
            snapshot,
            to: outputDirectory.appendingPathComponent("semantic-ui.json")
        )
        let report = UIProbeReport(
            width: Int(width),
            height: Int(height),
            interactionBefore: before,
            interactionAfter: after,
            semanticNodeCount: snapshot.nodes.count,
            observedActions: actions.map(String.init(describing:)),
            invariantViolations: violations
        )
        try WarrenArtifactWriter.writeJSON(
            report,
            to: outputDirectory.appendingPathComponent("result.json")
        )

        guard violations.isEmpty else {
            throw NSError(
                domain: "Warren.UIProbe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: violations.joined(separator: "\n")]
            )
        }
        print("semantic UI OK: \(snapshot.nodes.count) nodes -> \(outputDirectory.path)")
    }
}

try UIProbe.run()
