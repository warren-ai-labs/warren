import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

public enum WarrenDesktopWorkspaceContentMode: String, Hashable, Sendable {
    case terminal
    case editor
}

enum WarrenDesktopPresetLaunchFeedback {
    static func isDisabled(
        hasScope: Bool,
        isBusy: Bool,
        isPending: Bool
    ) -> Bool {
        !hasScope || isBusy || isPending
    }

    static func label(isPending: Bool) -> String {
        isPending ? "Starting…" : "Ready"
    }
}

/// Pinned command launchers between the workspace tabs and pane toolbar.
///
/// Superset calls this its PresetsBar. Warren keeps its executable built-ins
/// in one catalog; custom commands continue through the full session creator. Every
/// button emits a typed intent and creates a real Host-owned session.
struct WarrenDesktopPresetBar: View {
    let workspace: Workspace?
    let terminalGroup: TerminalGroup?
    let isBusy: Bool
    let onLaunch: (TerminalSessionLaunchRequest) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedPresetID: String?
    @State private var pendingPresetID: String?
    @State private var pendingResetGeneration = 0
    @AppStorage(WarrenPreferenceKey.presetCommandShell)
    private var shellCommand = ""
    @AppStorage(WarrenPreferenceKey.presetCommandClaude)
    private var claudeCommand = "claude"
    @AppStorage(WarrenPreferenceKey.presetCommandCodex)
    private var codexCommand = "codex --dangerously-bypass-hook-trust"
    @AppStorage(WarrenPreferenceKey.presetCommandOpenCode)
    private var opencodeCommand = "opencode"
    @AppStorage(WarrenPreferenceKey.presetCommandPi)
    private var piCommand = "pi"
    @AppStorage(WarrenPreferenceKey.presetCommandQoder)
    private var qoderCommand = "qoder"
    @AppStorage(WarrenPreferenceKey.presetCommandTrae)
    private var traeCommand = "trae-cli interactive"
    @AppStorage(WarrenPreferenceKey.sessionPresetOrder)
    private var presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
    @AppStorage(WarrenPreferenceKey.hiddenSessionPresets)
    private var hiddenPresets = WarrenDesktopSessionPreset.defaultHiddenRawValue

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenOverflowFadeScrollView(
            .horizontal,
            fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
            surface: tokens.background
        ) {
            HStack(spacing: WarrenSpacing.small) {
                ForEach(WarrenDesktopSessionPreset.orderedVisible(
                    by: presetOrder,
                    hidden: hiddenPresets
                )) { preset in
                    Button {
                        guard pendingPresetID == nil, !isBusy else { return }
                        pendingPresetID = preset.id
                        pendingResetGeneration &+= 1
                        let generation = pendingResetGeneration
                        onLaunch(preset.resolvedRequest(commandOverride: command(for: preset.id)))
                        // A disconnected client can reject the launch before
                        // the parent publishes its busy state. Clear only
                        // that orphaned visual pending state so the preset
                        // bar cannot remain disabled forever.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                            if pendingResetGeneration == generation {
                                pendingPresetID = nil
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            WarrenDesktopPresetIcon(preset: preset)
                                .frame(width: 16, height: 16)

                            Text(preset.presetBarTitle)
                                .font(.system(size: 13, weight: .light))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .contentShape(.rect)
                    }
                    .buttonStyle(WarrenPresetButtonStyle(isFocused: focusedPresetID == preset.id))
                    .focused($focusedPresetID, equals: preset.id)
                    .foregroundStyle(tokens.mutedForeground)
                    .disabled(WarrenDesktopPresetLaunchFeedback.isDisabled(
                        hasScope: workspace != nil || terminalGroup != nil,
                        isBusy: isBusy,
                        isPending: pendingPresetID != nil
                    ))
                    .opacity(pendingPresetID == preset.id ? 0.68 : 1)
                    .accessibilityValue(WarrenDesktopPresetLaunchFeedback.label(isPending: pendingPresetID == preset.id))
                    .accessibilityLabel("Start \(preset.title)")
                    .accessibilityHint("Create a session in \(scopeLabel)")
                }

                if isBusy {
                    Text("Starting…")
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .accessibilityLabel("Starting session")
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .frame(minWidth: 0, minHeight: WarrenLayoutMetrics.presetBarHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: WarrenLayoutMetrics.presetBarHeight)
        .background(tokens.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.chromeDivider)
                .frame(height: WarrenSpacing.hairline)
        }
        .onChange(of: isBusy) { busy in
            pendingResetGeneration &+= 1
            if !busy { pendingPresetID = nil }
        }
        .onChange(of: workspace?.id) { _ in
            pendingResetGeneration &+= 1
            pendingPresetID = nil
        }
        .onChange(of: terminalGroup?.id) { _ in
            pendingResetGeneration &+= 1
            pendingPresetID = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command presets")
    }

    private func command(for presetID: String) -> String {
        switch presetID {
        case "shell": shellCommand
        case "claude": claudeCommand
        case "codex": codexCommand
        case "opencode": opencodeCommand
        case "pi": piCommand
        case "qoder": qoderCommand
        case "trae": traeCommand
        default: ""
        }
    }

    private var scopeLabel: String {
        workspace?.name ?? terminalGroup?.name ?? "the selected terminal group"
    }
}

struct WarrenDesktopPresetIcon: View {
    let preset: WarrenDesktopSessionPreset

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .opacity(0.9)
                .scaleEffect(preset.id == "codex" ? 1.35 : 1)
                .accessibilityHidden(true)
        }
    }

    private var image: NSImage? {
        guard var name = preset.presetBarIconName else { return nil }
        if name == "preset-codex", colorScheme == .dark {
            name = "preset-codex-white"
        }
        return WarrenPresetIconCache.shared.image(named: name)
    }
}

@MainActor
final class WarrenPresetIconCache {
    typealias Loader = @MainActor (String) -> NSImage?

    static let shared = WarrenPresetIconCache { name in
        let packaged = Bundle.main.resourceURL?
            .appendingPathComponent("WarrenDesktop_WarrenDesktop.bundle", isDirectory: true)
            .appendingPathComponent("\(name).svg")
        let url = packaged.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? Bundle.module.url(forResource: name, withExtension: "svg")
        return url.flatMap(NSImage.init(contentsOf:))
    }

    private let loader: Loader
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func image(named name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard !missing.contains(name) else { return nil }
        guard let image = loader(name) else {
            missing.insert(name)
            return nil
        }
        images[name] = image
        return image
    }
}
