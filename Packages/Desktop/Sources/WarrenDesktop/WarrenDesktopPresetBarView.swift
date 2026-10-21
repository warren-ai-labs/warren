import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

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

/// The command launchers behind the top bar's "+" button.
///
/// They used to be a bar of their own under the tabs. They now live in the
/// "+" menu so the chrome above the terminal is one row. Warren keeps its
/// executable built-ins in one catalog; custom commands continue through the
/// full session creator. Every row emits a typed intent and creates a real
/// Host-owned session.
struct WarrenDesktopPresetBar: View {
    let workspace: Workspace?
    let isBusy: Bool
    /// Whether this endpoint can show the page a browser Session owns. A remote
    /// Host runs its Chromium on its own machine, so launching one from here
    /// would create a Session with nothing to look at.
    let canUseEmbeddedBrowser: Bool
    let onLaunch: (TerminalSessionLaunchRequest) -> Void

    /// Closes the "+" menu once a launch is on its way.
    var onDismiss: () -> Void = {}
    /// Opens Settings at the launch commands. Nil leaves the footer out.
    var onCustomize: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedPresetID: String?
    @State private var pendingPresetID: String?
    /// The ACP-capable preset whose inline Terminal/Chat choice is open.
    @State private var choosingPresetID: String?
    /// The row under the pointer, which shows its quick Terminal/Chat pair.
    @State private var hoveredPresetID: String?
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
    @AppStorage(WarrenPreferenceKey.presetCommandAntigravity)
    private var antigravityCommand = "agy"
    @AppStorage(WarrenPreferenceKey.presetCommandTrae)
    private var traeCommand = "trae-cli interactive"
    @AppStorage(WarrenPreferenceKey.sessionPresetOrder)
    private var presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
    @AppStorage(WarrenPreferenceKey.hiddenSessionPresets)
    private var hiddenPresets = WarrenDesktopSessionPreset.defaultHiddenRawValue
    @AppStorage(WarrenPreferenceKey.agentInterface)
    private var agentInterfaceRawValue = WarrenAgentInterface.defaultValue.rawValue

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        let presets = WarrenDesktopSessionPreset.orderedLaunchable(
            by: presetOrder,
            hidden: hiddenPresets,
            embeddedBrowser: canUseEmbeddedBrowser
        )
        ZStack(alignment: .topLeading) {
            if let choosingPresetID,
               let preset = presets.first(where: { $0.id == choosingPresetID }) {
                interfaceChoice(for: preset, palette: palette)
                    .transition(
                        WarrenDesktopPopMotion.pageTransition(isForward: true, reduceMotion: reduceMotion)
                    )
                    .id(choosingPresetID)
            } else {
                presetList(presets, palette: palette)
                    .transition(
                        WarrenDesktopPopMotion.pageTransition(isForward: false, reduceMotion: reduceMotion)
                    )
            }
        }
        .onChange(of: isBusy) { busy in
            if !busy { pendingPresetID = nil }
        }
        .onChange(of: workspace?.id) { _ in
            pendingPresetID = nil
            choosingPresetID = nil
        }
        .onChange(of: agentInterfaceRawValue) { _ in
            choosingPresetID = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command presets")
        // Named so tests and probes can find the menu once "+" opens it.
        .warrenSemanticElement(
            id: "preset-bar",
            role: .group,
            label: "Command presets"
        )
    }

    /// The menu's first page, in three groups: the plain launchers (Shell),
    /// the Agents, and anything else (Browser). The header names where the
    /// Session will land, so the menu never launches into a surprise.
    @ViewBuilder
    private func presetList(
        _ presets: [WarrenDesktopSessionPreset],
        palette: WarrenDesktopMenuPalette
    ) -> some View {
        let groups = Self.groups(presets)
        VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopMenuGroupHeader(title: "NEW SESSION") {
                scopeAccessory(palette: palette)
            }

            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    WarrenDesktopMenuDivider()
                }
                if let title = group.title {
                    WarrenDesktopMenuGroupHeader(title: title)
                }
                ForEach(group.presets) { preset in
                    presetButton(preset, tokens: palette)
                }
            }

            if let onCustomize {
                WarrenDesktopMenuDivider()
                customizeRow(onCustomize, palette: palette)
            }
        }
    }

    /// Where the Session lands, or that it is on its way.
    @ViewBuilder
    private func scopeAccessory(palette: WarrenDesktopMenuPalette) -> some View {
        if isBusy && pendingPresetID == nil {
            HStack(spacing: 5) {
                WarrenLoadingIndicator(size: 11, accessibilityLabel: "Starting session")
                Text("Starting…")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.meta)
            .padding(.trailing, WarrenDesktopMenuMetrics.rowHorizontalPadding - 2)
        } else if let workspace {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9.5, weight: .medium))
                Text(workspace.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.meta)
            .frame(maxWidth: 140, alignment: .trailing)
            .padding(.trailing, WarrenDesktopMenuMetrics.rowHorizontalPadding - 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("In \(workspace.name)")
        }
    }

    struct PresetGroup {
        let title: String?
        let presets: [WarrenDesktopSessionPreset]
    }

    /// Splits the ordered presets into the menu's groups, keeping the
    /// person's order inside each one and dropping a group that ends up
    /// empty.
    static func groups(_ presets: [WarrenDesktopSessionPreset]) -> [PresetGroup] {
        let agents = presets.filter(\.isAI)
        let browsers = presets.filter { $0.request.kind == .browser }
        let launchers = presets.filter { !$0.isAI && $0.request.kind != .browser }
        return [
            PresetGroup(title: nil, presets: launchers),
            PresetGroup(title: "AGENTS", presets: agents),
            PresetGroup(title: nil, presets: browsers),
        ]
        .filter { !$0.presets.isEmpty }
    }

    /// The way to the commands behind each row, in the quiet add-row style
    /// the Host panels use.
    private func customizeRow(
        _ onCustomize: @escaping () -> Void,
        palette: WarrenDesktopMenuPalette
    ) -> some View {
        let action: () -> Void = {
            onDismiss()
            onCustomize()
        }
        return Button(action: action) {
            HStack(spacing: WarrenDesktopMenuMetrics.iconSpacing) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: WarrenDesktopMenuMetrics.iconSize, height: WarrenDesktopMenuMetrics.iconSize)
                Text("Launch commands…")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.addText)
            .padding(.horizontal, Self.rowHorizontalInset)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .accessibilityLabel("Edit launch commands")
        .warrenSemanticElement(
            id: "preset.customize",
            role: .button,
            label: "Edit launch commands",
            action: action
        )
    }

    private var isLaunchDisabled: Bool {
        WarrenDesktopPresetLaunchFeedback.isDisabled(
            hasScope: workspace != nil,
            isBusy: isBusy,
            isPending: pendingPresetID != nil
        )
    }

    static let menuWidth: CGFloat = 248
    static let rowHeight: CGFloat = WarrenDesktopMenuMetrics.rowHeight
    static let rowHorizontalInset: CGFloat = WarrenDesktopMenuMetrics.rowHorizontalPadding

    /// The key the app menu binds to a preset: "New Session" (⌘T) starts
    /// the default Shell.
    static func shortcut(for preset: WarrenDesktopSessionPreset) -> String? {
        preset.id == "shell" ? "⌘T" : nil
    }

    private func presetButton(
        _ preset: WarrenDesktopSessionPreset,
        tokens palette: WarrenDesktopMenuPalette
    ) -> some View {
        let isPending = pendingPresetID == preset.id
        let isHot = hoveredPresetID == preset.id && !isLaunchDisabled
        let showsQuickChoice = preset.supportsConversation && isHot
        return Button {
            press(preset)
        } label: {
            HStack(spacing: WarrenDesktopMenuMetrics.iconSpacing) {
                // The same app icon the Session will wear in the tree and on
                // its Tab.
                // A starting row trades it for the spinner, as the menu spec
                // draws a loading row.
                if isPending {
                    WarrenLoadingIndicator(size: 12, accessibilityLabel: "Starting \(preset.title)")
                        .frame(width: WarrenDesktopMenuMetrics.iconSize, height: WarrenDesktopMenuMetrics.iconSize)
                } else {
                    WarrenDesktopSessionKindBadge(kind: preset.request.kind, size: WarrenDesktopMenuMetrics.iconSize)
                }

                Text(preset.presetBarTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(isHot ? palette.rowHoverText : palette.rowText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isPending {
                    EmptyView()
                } else if showsQuickChoice {
                    // The quick pair overlays this end of the row; keep its
                    // width so the title does not run under it.
                    Color.clear
                        .frame(width: WarrenDesktopMenuMetrics.actionSize * 2 + 2, height: 1)
                } else if let shortcut = Self.shortcut(for: preset) {
                    WarrenDesktopMenuKeycaps(keys: shortcut)
                } else if preset.supportsConversation, interface == .ask {
                    // "Ask each time" opens a second page for these.
                    WarrenDesktopMenuChevron()
                }
            }
            .padding(.horizontal, Self.rowHorizontalInset)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .focused($focusedPresetID, equals: preset.id)
        .disabled(isLaunchDisabled)
        .overlay(alignment: .trailing) {
            if showsQuickChoice && !isPending {
                quickChoice(for: preset)
                    .padding(.trailing, Self.rowHorizontalInset - 4)
                    .transition(.opacity)
            }
        }
        // After the overlay, so moving onto the quick pair keeps the row hot.
        .onHover { inside in
            if inside {
                hoveredPresetID = preset.id
            } else if hoveredPresetID == preset.id {
                hoveredPresetID = nil
            }
        }
        .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: showsQuickChoice)
        .accessibilityValue(WarrenDesktopPresetLaunchFeedback.label(isPending: isPending))
        .accessibilityLabel("Start \(preset.title)")
        .accessibilityHint("Create a session in \(scopeLabel)")
        .warrenSemanticElement(
            id: "preset.\(preset.id)",
            role: .button,
            label: "Start \(preset.title)",
            isEnabled: !isLaunchDisabled,
            isSelected: choosingPresetID == preset.id,
            action: { press(preset) }
        )
    }

    /// Terminal and Chat side by side on an ACP-capable row's hover, so
    /// either interface is one click away whatever Settings says the row
    /// itself does.
    private func quickChoice(for preset: WarrenDesktopSessionPreset) -> some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { conversation in
                let label = conversation
                    ? "Start \(preset.presetBarTitle) as Chat"
                    : "Start \(preset.presetBarTitle) in Terminal"
                let start = {
                    guard pendingPresetID == nil, !isBusy else { return }
                    launch(preset, conversation: conversation)
                }
                WarrenDesktopMenuInlineButton(
                    systemImage: conversation ? "bubble.left" : "terminal",
                    label: label,
                    action: start
                )
                .warrenSemanticElement(
                    id: "preset.\(preset.id).quick.\(conversation ? "chat" : "terminal")",
                    role: .button,
                    label: label,
                    isEnabled: !isLaunchDisabled,
                    action: start
                )
            }
        }
    }

    private var interface: WarrenAgentInterface {
        WarrenAgentInterface(storedValue: agentInterfaceRawValue)
    }

    private func press(_ preset: WarrenDesktopSessionPreset) {
        guard pendingPresetID == nil, !isBusy else { return }
        if preset.supportsConversation, interface == .ask {
            // A second click on the same preset folds the choice away.
            choosingPresetID = choosingPresetID == preset.id ? nil : preset.id
            return
        }
        launch(preset, conversation: interface == .acp)
    }

    /// The second step for "Ask each time": the same preset as its terminal
    /// CLI or as a Chat over ACP, stacked under the clicked preset.
    private func interfaceChoice(
        for preset: WarrenDesktopSessionPreset,
        palette: WarrenDesktopMenuPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopMenuBackRow(
                title: preset.presetBarTitle,
                backLabel: "Back to presets",
                onBack: { choosingPresetID = nil }
            ) {
                WarrenDesktopSessionKindBadge(kind: preset.request.kind, size: 14)
                    .padding(.trailing, 2)
            }

            WarrenDesktopMenuDivider()

            ForEach([false, true], id: \.self) { conversation in
                let label = conversation ? "Chat" : "Terminal"
                let hint = conversation ? "Conversation over ACP, with approvals" : "The provider's own CLI"
                let id = "\(preset.id).\(conversation ? "chat" : "terminal")"
                let choose = {
                    guard pendingPresetID == nil, !isBusy else { return }
                    launch(preset, conversation: conversation)
                }
                Button(action: choose) {
                    HStack(spacing: WarrenDesktopMenuMetrics.iconSpacing) {
                        Image(systemName: conversation ? "bubble.left" : "terminal")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(palette.icon)
                            .frame(
                                width: WarrenDesktopMenuMetrics.glyphSlot,
                                height: WarrenDesktopMenuMetrics.glyphSlot
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label)
                                .font(.system(size: 13))
                                .foregroundStyle(palette.rowText)
                            Text(hint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.meta)
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, WarrenDesktopMenuMetrics.rowHorizontalPadding)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: WarrenDesktopMenuMetrics.twoLineRowHeight,
                        alignment: .leading
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(WarrenDesktopMenuRowStyle())
                .focused($focusedPresetID, equals: id)
                .disabled(isLaunchDisabled)
                .accessibilityLabel("Start \(preset.title) as \(label)")
                .warrenSemanticElement(
                    id: "preset.\(preset.id).\(conversation ? "chat" : "terminal")",
                    role: .button,
                    label: "Start \(preset.title) as \(label)",
                    isEnabled: !isLaunchDisabled,
                    action: choose
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(preset.presetBarTitle) interface")
    }

    private func launch(_ preset: WarrenDesktopSessionPreset, conversation: Bool) {
        choosingPresetID = nil
        defer { onDismiss() }
        // The double-click guard. The menu closes on launch, which drops
        // this state with it, so nothing has to time it out.
        pendingPresetID = preset.id
        onLaunch(preset.resolvedRequest(
            commandOverride: command(for: preset.id),
            conversation: conversation
        ))
    }

    private func command(for presetID: String) -> String {
        switch presetID {
        case "shell": shellCommand
        case "claude": claudeCommand
        case "codex": codexCommand
        case "opencode": opencodeCommand
        case "pi": piCommand
        case "qoder": qoderCommand
        case "antigravity": antigravityCommand
        case "trae": traeCommand
        default: ""
        }
    }

    private var scopeLabel: String {
        workspace?.name ?? "the selected workspace"
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

    /// - Parameter template: Marks the image as a tintable mask. `isTemplate`
    ///   is a property of the instance, so the template and the as-authored
    ///   copies of one artwork are cached apart: a brand mark drawn white on
    ///   its tile is the same file the preset menu draws in colour.
    func image(named name: String, template: Bool = false) -> NSImage? {
        let key = template ? name + "#template" : name
        if let image = images[key] { return image }
        guard !missing.contains(name) else { return nil }
        guard let image = loader(name) else {
            missing.insert(name)
            return nil
        }
        image.isTemplate = template
        images[key] = image
        return image
    }
}
