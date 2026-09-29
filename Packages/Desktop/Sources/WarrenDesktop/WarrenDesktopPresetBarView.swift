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

/// Pinned command launchers between the workspace tabs and pane toolbar.
///
/// Superset calls this its PresetsBar. Warren keeps its executable built-ins
/// in one catalog; custom commands continue through the full session creator. Every
/// button emits a typed intent and creates a real Host-owned session.
struct WarrenDesktopPresetBar: View {
    let workspace: Workspace?
    let terminalGroup: TerminalGroup?
    let isBusy: Bool
    /// Whether this endpoint can show the page a browser Session owns. A remote
    /// Host runs its Chromium on its own machine, so launching one from here
    /// would create a Session with nothing to look at.
    let canUseEmbeddedBrowser: Bool
    let onLaunch: (TerminalSessionLaunchRequest) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedPresetID: String?
    @State private var pendingPresetID: String?
    @State private var pendingResetGeneration = 0
    /// The ACP-capable preset whose inline Terminal/Chat choice is open.
    @State private var choosingPresetID: String?
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
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenOverflowFadeScrollView(
            .horizontal,
            fadeLength: WarrenLayoutMetrics.sidebarScrollFadeLength,
            surface: tokens.background
        ) {
            HStack(spacing: WarrenSpacing.small) {
                ForEach(WarrenDesktopSessionPreset.orderedLaunchable(
                    by: presetOrder,
                    hidden: hiddenPresets,
                    embeddedBrowser: canUseEmbeddedBrowser
                )) { preset in
                    presetButton(preset, tokens: tokens)
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
            choosingPresetID = nil
        }
        .onChange(of: terminalGroup?.id) { _ in
            pendingResetGeneration &+= 1
            pendingPresetID = nil
            choosingPresetID = nil
        }
        .onChange(of: agentInterfaceRawValue) { _ in
            choosingPresetID = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command presets")
        // Named so a test can assert the bar survives opening the editor. It
        // used to be removed with the terminal layout, which is the regression
        // RFC 0021 §8-3 is about.
        .warrenSemanticElement(
            id: "preset-bar",
            role: .group,
            label: "Command presets"
        )
    }

    private var isLaunchDisabled: Bool {
        WarrenDesktopPresetLaunchFeedback.isDisabled(
            hasScope: workspace != nil || terminalGroup != nil,
            isBusy: isBusy,
            isPending: pendingPresetID != nil
        )
    }

    private func presetButton(_ preset: WarrenDesktopSessionPreset, tokens: WarrenColorTokens) -> some View {
        Button {
            press(preset)
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
        .foregroundStyle(choosingPresetID == preset.id ? tokens.foreground : tokens.mutedForeground)
        .disabled(isLaunchDisabled)
        .opacity(pendingPresetID == preset.id ? 0.68 : 1)
        .accessibilityValue(WarrenDesktopPresetLaunchFeedback.label(isPending: pendingPresetID == preset.id))
        .accessibilityLabel("Start \(preset.title)")
        .accessibilityHint("Create a session in \(scopeLabel)")
        .popover(
            isPresented: Binding(
                get: { choosingPresetID == preset.id },
                set: { if !$0, choosingPresetID == preset.id { choosingPresetID = nil } }
            ),
            arrowEdge: .bottom
        ) {
            interfaceChoice(for: preset, tokens: tokens)
        }
        .warrenSemanticElement(
            id: "preset.\(preset.id)",
            role: .button,
            label: "Start \(preset.title)",
            isEnabled: !isLaunchDisabled,
            isSelected: choosingPresetID == preset.id,
            action: { press(preset) }
        )
    }

    private func press(_ preset: WarrenDesktopSessionPreset) {
        guard pendingPresetID == nil, !isBusy else { return }
        let interface = WarrenAgentInterface(storedValue: agentInterfaceRawValue)
        if preset.supportsConversation, interface == .ask {
            // A second click on the same preset folds the choice away.
            choosingPresetID = choosingPresetID == preset.id ? nil : preset.id
            return
        }
        launch(preset, conversation: interface == .acp)
    }

    /// The second step for "Ask each time": the same preset as its terminal
    /// CLI or as a Chat over ACP, stacked under the clicked preset.
    private func interfaceChoice(for preset: WarrenDesktopSessionPreset, tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([false, true], id: \.self) { conversation in
                let label = conversation ? "Chat" : "Terminal"
                let hint = conversation ? "Conversation over ACP, with approvals" : "The provider's own CLI"
                let id = "\(preset.id).\(conversation ? "chat" : "terminal")"
                let choose = {
                    guard pendingPresetID == nil, !isBusy else { return }
                    launch(preset, conversation: conversation)
                }
                Button(action: choose) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(tokens.foreground)
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(WarrenPresetButtonStyle(isFocused: focusedPresetID == id))
                .focused($focusedPresetID, equals: id)
                .disabled(isLaunchDisabled)
                .accessibilityLabel("Start \(preset.title) as \(label)")
            }
        }
        .padding(4)
        .frame(width: 240)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(preset.presetBarTitle) interface")
    }

    private func launch(_ preset: WarrenDesktopSessionPreset, conversation: Bool) {
        choosingPresetID = nil
        pendingPresetID = preset.id
        pendingResetGeneration &+= 1
        let generation = pendingResetGeneration
        onLaunch(preset.resolvedRequest(
            commandOverride: command(for: preset.id),
            conversation: conversation
        ))
        // A disconnected client can reject the launch before
        // the parent publishes its busy state. Clear only
        // that orphaned visual pending state so the preset
        // bar cannot remain disabled forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if pendingResetGeneration == generation {
                pendingPresetID = nil
            }
        }
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
        workspace?.name ?? terminalGroup?.name ?? "the selected terminal group"
    }
}

struct WarrenDesktopPresetIcon: View {
    let preset: WarrenDesktopSessionPreset

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = image {
            let artwork = Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(preset.presetBarIconName == "preset-codex" ? 1.35 : 1)
                .accessibilityHidden(true)
            if preset.presetBarIconIsTintable {
                // A template image takes the foreground style, so the glyph is
                // painted from the resolved token instead of from the grey the
                // asset was authored with. The tint already carries the right
                // weight for the appearance, so it does not also need the 0.9
                // that softens the brand marks against Ember.
                artwork
                    .foregroundStyle(
                        WarrenColorTokens.resolved(for: colorScheme).mutedForeground
                    )
            } else {
                artwork.opacity(0.9)
            }
        } else {
            Image(systemName: preset.symbolName)
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)
        }
    }

    private var image: NSImage? {
        guard var name = preset.presetBarIconName else { return nil }
        // Codex's mark is two-tone, so it swaps artwork rather than being
        // tinted: a template image would flatten its inner counter-shape.
        if name == "preset-codex", colorScheme == .dark {
            name = "preset-codex-white"
        }
        return WarrenPresetIconCache.shared.image(
            named: name,
            template: preset.presetBarIconIsTintable
        )
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

    /// - Parameter template: Marks the image as a tintable mask. Set once, when
    ///   the image is first loaded, because the cache hands the same instance to
    ///   every call site and `isTemplate` is a property of that instance.
    func image(named name: String, template: Bool = false) -> NSImage? {
        if let image = images[name] { return image }
        guard !missing.contains(name) else { return nil }
        guard let image = loader(name) else {
            missing.insert(name)
            return nil
        }
        image.isTemplate = template
        images[name] = image
        return image
    }
}
