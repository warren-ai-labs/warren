import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain

/// Settings mirror Superset's route layout: a slim window-chrome row on top,
/// a 224pt sidebar with Back/title/search/grouped navigation on the left, and
/// a page-headed detail column (`max-w-5xl`) on the right.
struct WarrenDesktopSettingsView: View {
    let onBack: () -> Void
    let defaultRuntime: String?
    let onSetRuntime: (String) -> Void
    let autoOpenShell: Bool
    let onSetAutoOpenShell: (Bool) -> Void
    let autoStartAI: Bool
    let onSetAutoStartAI: (Bool) -> Void

    @AppStorage(WarrenPreferenceKey.terminalTitleTemplate)
    private var titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
    @AppStorage(WarrenPreferenceKey.terminalFontFamily)
    private var fontFamily = TerminalFontPreference.defaultFamily
    @AppStorage(WarrenPreferenceKey.terminalFontSize)
    private var fontSize = TerminalFontPreference.defaultSize
    @AppStorage(WarrenPreferenceKey.presetCommandShell)
    private var shellCommand = ""
    @AppStorage(WarrenPreferenceKey.presetCommandClaude)
    private var claudeCommand = "claude"
    @AppStorage(WarrenPreferenceKey.presetCommandCodex)
    private var codexCommand = "codex --dangerously-bypass-hook-trust"
    @AppStorage(WarrenPreferenceKey.sessionPresetOrder)
    private var presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
    @AppStorage(WarrenPreferenceKey.gnarSharingEnabled)
    private var gnarSharingEnabled = true
    @Environment(\.colorScheme) private var colorScheme

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case terminalFont = "Font"
        case terminalTitle = "Title"
        case terminalRuntime = "Terminal runtime"
        case presets = "Presets"
        case workspaces = "Workspaces"
        case externalIDEs = "External IDEs"
        case webSharing = "Web sharing"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .terminalFont: "terminal"
            case .terminalTitle: "textformat"
            case .terminalRuntime: "cpu"
            case .presets: "hammer"
            case .workspaces: "arrow.triangle.branch"
            case .externalIDEs: "chevron.left.forwardslash.chevron.right"
            case .webSharing: "globe"
            }
        }

        var detail: String {
            switch self {
            case .terminalFont: "Applied to every terminal surface."
            case .terminalTitle: "Build a title from live Session metadata."
            case .terminalRuntime: "Engine that owns new sessions on the headless daemon."
            case .presets: "Commands launched by the Shell, Claude and Codex buttons."
            case .workspaces: "How projects import worktrees and enter sessions."
            case .externalIDEs: "IDEs the workspace menu can open worktrees in."
            case .webSharing: "Publish the Web UI to the public internet."
            }
        }

        var searchTerms: [String] {
            switch self {
            case .terminalFont: [rawValue, detail, "font", "family", "size", "typography"]
            case .terminalTitle: [rawValue, detail, "title", "template", "placeholder", "preview"]
            case .terminalRuntime: [rawValue, detail, "ghostline", "tmux", "runtime", "engine", "session", "headless"]
            case .presets: [rawValue, detail, "preset", "command", "launch", "shell", "claude", "codex", "agent"]
            case .workspaces: [rawValue, detail, "workspace", "project", "git", "worktree", "import", "checkout", "shell", "AI", "Claude", "Codex"]
            case .externalIDEs: [rawValue, detail, "ide", "editor", "vscode", "goland", "android", "custom", "path", "open"]
            case .webSharing: [rawValue, detail, "gnar", "share", "public", "tunnel", "internet"]
            }
        }

        var isTerminalSection: Bool {
            switch self {
            case .terminalFont, .terminalTitle, .terminalRuntime, .presets, .workspaces, .externalIDEs: true
            case .webSharing: false
            }
        }
    }

    @State private var selectedSection: SettingsSection = .terminalFont
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var installedIDEs: [InstalledIDE] = []
    @State private var customIDEs = WarrenDesktopCustomIDEStore.load()

    private var visibleSections: [SettingsSection] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            section.searchTerms.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            chromeRow(tokens: tokens)

            WarrenDesktopChromeDivider()

            HStack(spacing: 0) {
                navigationPanel(tokens: tokens)
                    .frame(width: WarrenLayoutMetrics.settingsNavigationWidth)

                Rectangle()
                    .fill(tokens.border)
                    .frame(width: WarrenSpacing.hairline)

                detailPanel(tokens: tokens)
            }
        }
        .background(tokens.background)
        .onExitCommand(perform: onBack)
        .onChange(of: searchQuery) { _, _ in
            if !visibleSections.contains(selectedSection), let first = visibleSections.first {
                selectedSection = first
            }
        }
    }

    private func chromeRow(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: 0) {
            WarrenDesktopTrafficLights()
                .frame(width: WarrenLayoutMetrics.macTrafficLightInset, alignment: .leading)

            WarrenDesktopWindowDragRegion()
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
        .background(tokens.chromeSurface)
    }

    private func navigationPanel(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: WarrenSpacing.small) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Back")
                }
                .font(WarrenTypography.settingsNavigationItem)
                .padding(.horizontal, WarrenSpacing.compact)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenInteractiveRowStyle())
            .padding(.horizontal, WarrenSpacing.xs)
            .accessibilityLabel("Back to Warren")

            Text("Settings")
                .font(WarrenTypography.settingsScreenTitle)
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.top, WarrenSpacing.standard)
                .padding(.bottom, WarrenSpacing.large)

            searchField(tokens: tokens)
                .padding(.horizontal, WarrenSpacing.xs)
                .padding(.bottom, WarrenSpacing.medium)

            ScrollView {
                VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                    groupLabel("Terminal", tokens: tokens)
                    ForEach(visibleSections.filter(\.isTerminalSection)) { section in
                        navigationItem(section, tokens: tokens)
                    }

                    groupLabel("Web", tokens: tokens)
                    ForEach(visibleSections.filter { !$0.isTerminalSection }) { section in
                        navigationItem(section, tokens: tokens)
                    }

                    if visibleSections.isEmpty {
                        Text("No settings match your search")
                            .font(WarrenTypography.body)
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, WarrenSpacing.large)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tokens.sidebarSurface)
    }

    private func groupLabel(_ title: String, tokens: WarrenColorTokens) -> some View {
        Text(title)
            .font(WarrenTypography.settingsGroupLabel)
            .textCase(.uppercase)
            .tracking(1.0)
            .foregroundStyle(tokens.mutedForeground)
            .padding(.horizontal, WarrenSpacing.standard)
            .padding(.top, WarrenSpacing.large)
            .padding(.bottom, WarrenSpacing.small)
    }

    private func searchField(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 16)
                .accessibilityHidden(true)

            TextField("Search settings…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(WarrenTypography.navigationItem)
                .focused($searchFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .frame(height: WarrenLayoutMetrics.settingsSearchHeight)
        .background(tokens.muted.opacity(0.45))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .overlay {
            RoundedRectangle(cornerRadius: WarrenRadius.row)
                .stroke(searchFocused ? tokens.ring : .clear, lineWidth: WarrenSpacing.hairline)
        }
    }

    private func navigationItem(
        _ section: SettingsSection,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: section.iconName)
                    .font(.system(size: 12, weight: .light))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                    .accessibilityHidden(true)

                Text(section.rawValue)
                    .font(WarrenTypography.settingsNavigationItem)
                    .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.standard)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected))
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("settings.section.\(section.id)")
    }

    private func detailPanel(tokens: WarrenColorTokens) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WarrenSpacing.xxlarge) {
                switch selectedSection {
                case .terminalFont:
                    terminalFontSection(tokens: tokens)
                case .terminalTitle:
                    terminalTitleSection(tokens: tokens)
                case .terminalRuntime:
                    terminalRuntimeSection(tokens: tokens)
                case .presets:
                    presetsSection(tokens: tokens)
                case .workspaces:
                    workspacesSection(tokens: tokens)
                case .externalIDEs:
                    externalIDEsSection(tokens: tokens)
                case .webSharing:
                    webSharingSection(tokens: tokens)
                }

                Button("Restore terminal defaults") {
                    titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
                    fontFamily = TerminalFontPreference.defaultFamily
                    fontSize = TerminalFontPreference.defaultSize
                    shellCommand = ""
                    claudeCommand = "claude"
                    codexCommand = "codex --dangerously-bypass-hook-trust"
                    presetOrder = WarrenDesktopSessionPreset.defaultOrderRawValue
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .padding(.top, WarrenSpacing.medium)
                .accessibilityIdentifier("settings.restore-defaults")
            }
            .frame(maxWidth: WarrenLayoutMetrics.settingsContentMaxWidth, alignment: .leading)
            .padding(.horizontal, WarrenSpacing.xlarge)
            .padding(.vertical, WarrenSpacing.xxlarge)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .id(selectedSection)
        }
    }

    private func terminalFontSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal font", section: .terminalFont, tokens: tokens) {
            HStack(alignment: .bottom, spacing: WarrenSpacing.xlarge) {
                WarrenInputField(
                    "Font family",
                    text: $fontFamily,
                    placeholder: TerminalFontPreference.defaultFamily
                )
                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                    Text("Size").font(WarrenTypography.bodyEmphasis)
                    Stepper(value: $fontSize, in: 8...32, step: 1) {
                        Text("\(Self.fontSizeLabel(fontSize)) pt")
                            .font(WarrenTypography.code)
                            .frame(width: 44, alignment: .leading)
                    }
                }
                .frame(width: 150)
            }
            Text("$  The quick brown fox  0123456789  中文  │─└")
                .font(.custom(normalizedFont.family, size: normalizedFont.size))
                .foregroundStyle(tokens.foreground)
                .padding(WarrenSpacing.xlarge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tokens.fillHover)
                .clipShape(.rect(cornerRadius: WarrenRadius.medium))
        }
    }

    private static func fontSizeLabel(_ value: Double) -> String {
        let safe = value.isFinite
            ? min(max(value, 8), 32)
            : TerminalFontPreference.defaultSize
        return String(Int(safe))
    }

    private func terminalTitleSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal title", section: .terminalTitle, tokens: tokens) {
            WarrenInputField(
                "Title template",
                text: $titleTemplate,
                placeholder: "Title template"
            )
            Text(preview)
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: WarrenSpacing.compact)],
                alignment: .leading,
                spacing: WarrenSpacing.compact
            ) {
                ForEach(TerminalDisplayTitleTemplate.placeholders, id: \.token) { placeholder in
                    Button {
                        if !titleTemplate.isEmpty, !titleTemplate.hasSuffix(" ") { titleTemplate += " " }
                        titleTemplate += placeholder.token
                    } label: {
                        HStack {
                            Text(placeholder.token).font(WarrenTypography.compactCode)
                            Spacer()
                            Text(placeholder.description)
                                .font(WarrenTypography.navigationMeta)
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .padding(WarrenSpacing.compact)
                        .background(tokens.fillHover)
                        .clipShape(.rect(cornerRadius: WarrenRadius.small))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func presetsSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Launch commands", section: .presets, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                Text("Session order")
                    .font(WarrenTypography.bodyEmphasis)
                Text("This order controls the preset buttons; opening a workspace never changes it.")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: WarrenSpacing.small) {
                    ForEach(Array(orderedPresets.enumerated()), id: \.element.id) { index, preset in
                        HStack(spacing: WarrenSpacing.compact) {
                            Image(systemName: preset.symbolName)
                                .frame(width: 18)
                                .foregroundStyle(tokens.mutedForeground)
                            Text(preset.presetBarTitle)
                                .font(WarrenTypography.body)
                            Spacer()
                            presetMoveButton(
                                preset: preset,
                                direction: -1,
                                symbolName: "arrow.up",
                                disabled: index == 0,
                                tokens: tokens
                            )
                            presetMoveButton(
                                preset: preset,
                                direction: 1,
                                symbolName: "arrow.down",
                                disabled: index == orderedPresets.count - 1,
                                tokens: tokens
                            )
                        }
                        .padding(.horizontal, WarrenSpacing.standard)
                        .frame(minHeight: 38)
                        .background(tokens.fillHover)
                        .clipShape(.rect(cornerRadius: WarrenRadius.small))
                    }
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.xlarge) {
                ForEach(orderedPresets) { preset in
                    presetCommandField(for: preset)
                }
            }
            Text(
                "Commands are typed into a plain shell after it opens, so "
                    + "quitting an agent with Ctrl+C / Ctrl+D keeps the "
                    + "terminal tab alive. Leave Shell empty for a bare "
                    + "terminal."
            )
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var orderedPresets: [WarrenDesktopSessionPreset] {
        WarrenDesktopSessionPreset.orderedPinned(by: presetOrder)
    }

    private func presetMoveButton(
        preset: WarrenDesktopSessionPreset,
        direction: Int,
        symbolName: String,
        disabled: Bool,
        tokens: WarrenColorTokens
    ) -> some View {
        let directionLabel = direction < 0 ? "up" : "down"
        return Button {
            presetOrder = WarrenDesktopSessionPreset.moving(preset.id, by: direction, in: presetOrder)
        } label: {
            Image(systemName: symbolName)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tokens.mutedForeground)
        .disabled(disabled)
        .accessibilityLabel("Move \(preset.presetBarTitle) \(directionLabel)")
        .accessibilityIdentifier("settings.preset-order.\(preset.id).\(directionLabel)")
    }

    @ViewBuilder
    private func presetCommandField(for preset: WarrenDesktopSessionPreset) -> some View {
        switch preset.request.kind {
        case .shell:
            WarrenInputField("Shell", text: $shellCommand, placeholder: "default shell (empty)")
        case .claude:
            WarrenInputField("Claude", text: $claudeCommand, placeholder: "claude")
        case .codex:
            WarrenInputField(
                "Codex",
                text: $codexCommand,
                placeholder: "codex --dangerously-bypass-hook-trust"
            )
        case .custom:
            EmptyView()
        }
    }

    private func workspacesSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Workspaces", section: .workspaces, tokens: tokens) {
            Toggle("Open a Shell when opening an empty workspace", isOn: Binding(
                get: { autoOpenShell },
                set: { onSetAutoOpenShell($0) }
            ))
            .toggleStyle(.switch)
            .accessibilityIdentifier("settings.workspaces.auto-open-shell")
            Text(
                "Double-clicking an empty workspace is the explicit open action. "
                    + "When this is enabled, it creates one Shell. If automatic "
                    + "AI startup is also enabled, the AI rule wins and no second "
                    + "Shell is created. Explicit New Session and preset buttons "
                    + "always create the requested session."
            )
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Start the first AI when entering an empty workspace", isOn: Binding(
                get: { autoStartAI },
                set: { onSetAutoStartAI($0) }
            ))
            .toggleStyle(.switch)
            .accessibilityIdentifier("settings.workspaces.auto-start-ai")
            Text(
                "Selecting a workspace, selecting a project, or using the Command "
                    + "Palette starts the first AI in Launch commands order. This "
                    + "does not run during navigation restore. If both options are "
                    + "enabled, this AI startup takes precedence over the Shell "
                    + "option on a double-click, preventing duplicate sessions."
            )
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "Git worktree import is configured per project. Use a project's "
                    + "context menu to enable automatic import (no confirmation) "
                    + "or choose Import Existing Worktrees… for a one-time selection."
            )
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func externalIDEsSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("External IDEs", section: .externalIDEs, tokens: tokens) {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                Text("Installed").font(WarrenTypography.bodyEmphasis)
                if installedIDEs.isEmpty {
                    Text("No supported IDEs found on this Mac.")
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.mutedForeground)
                }
                ForEach(installedIDEs) { ide in
                    ideRow(icon: ide.icon, name: ide.name, path: ide.path, tokens: tokens)
                }
            }

            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                Text("Custom").font(WarrenTypography.bodyEmphasis)
                if customIDEs.isEmpty {
                    Text("No custom IDEs yet.")
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.mutedForeground)
                }
                ForEach(customIDEs) { ide in
                    HStack(spacing: WarrenSpacing.compact) {
                        Image(nsImage: WarrenDesktopExternalIDEIcon.normalized(
                            NSWorkspace.shared.icon(forFile: ide.path)
                        ))
                            .resizable()
                            .scaledToFit()
                            .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                                   height: WarrenLayoutMetrics.externalIDEIconSize)
                        Text(ide.name).font(WarrenTypography.externalIDEName)
                        Spacer()
                        Text(ide.path)
                            .font(WarrenTypography.externalIDEPath)
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(role: .destructive) {
                            removeCustomIDE(ide)
                        } label: {
                            Image(systemName: "trash")
                                .font(WarrenTypography.navigationMeta)
                                .frame(width: WarrenLayoutMetrics.sidebarActionButtonSize,
                                       height: WarrenLayoutMetrics.sidebarActionButtonSize)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tokens.mutedForeground)
                        .accessibilityLabel("Remove \(ide.name)")
                    }
                    .padding(WarrenSpacing.compact)
                    .background(tokens.fillHover)
                    .clipShape(.rect(cornerRadius: WarrenRadius.small))
                }
                Button {
                    addCustomIDE()
                } label: {
                    Label("Add IDE…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .font(WarrenTypography.externalIDEName)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityIdentifier("settings.external-ides.add")
            }

            Text(
                "The workspace menu lists IDEs installed on this Mac plus "
                    + "your custom entries. A custom entry can be an app "
                    + "bundle or an executable that opens a directory, for "
                    + "example /usr/local/bin/code."
            )
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            installedIDEs = Self.probeInstalledIDEs()
        }
    }

    private func ideRow(
        icon: NSImage,
        name: String,
        path: String,
        tokens: WarrenColorTokens
    ) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                       height: WarrenLayoutMetrics.externalIDEIconSize)
            Text(name).font(WarrenTypography.externalIDEName)
            Spacer()
            Text(path)
                .font(WarrenTypography.externalIDEPath)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(WarrenSpacing.compact)
        .background(tokens.fillHover)
        .clipShape(.rect(cornerRadius: WarrenRadius.small))
    }

    private func addCustomIDE() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle, .executable]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose an IDE app bundle or executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ide = WarrenDesktopCustomIDE(name: Self.displayName(for: url), path: url.path)
        customIDEs.append(ide)
        WarrenDesktopCustomIDEStore.save(customIDEs)
    }

    private func removeCustomIDE(_ ide: WarrenDesktopCustomIDE) {
        customIDEs.removeAll { $0.id == ide.id }
        WarrenDesktopCustomIDEStore.save(customIDEs)
    }

    private static func displayName(for url: URL) -> String {
        if let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func probeInstalledIDEs() -> [InstalledIDE] {
        WarrenDesktopExternalIDE.supported.compactMap { ide in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ide.bundleIdentifier) else {
                return nil
            }
            return InstalledIDE(
                id: ide.id.rawValue,
                name: ide.name,
                path: url.path,
                icon: WarrenDesktopExternalIDEIcon.normalized(
                    NSWorkspace.shared.icon(forFile: url.path),
                    opticalScale: WarrenDesktopExternalIDEIcon.opticalScale(for: ide.id.rawValue)
                )
            )
        }
    }

    private func webSharingSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Web sharing", section: .webSharing, tokens: tokens) {
            Toggle("Share with gnar", isOn: $gnarSharingEnabled)
                .toggleStyle(.switch)
                .accessibilityIdentifier("settings.web-sharing.gnar-enabled")
            Text(
                "Publishes this Mac's Web UI through the gnar tunnel installed "
                    + "and signed in on this Mac. Run `gnar login --edge <url>` first."
            )
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runtimeSelection: Binding<String> {
        Binding(
            get: { defaultRuntime ?? "ghostline" },
            set: { onSetRuntime($0) }
        )
    }

    private func terminalRuntimeSection(tokens: WarrenColorTokens) -> some View {
        settingsSection("Terminal runtime", section: .terminalRuntime, tokens: tokens) {
            Picker("Default runtime", selection: runtimeSelection) {
                Text("ghostline (recommended)").tag("ghostline")
                Text("tmux").tag("tmux")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.terminal-runtime.picker")

            Text(
                "This is a headless-daemon setting: the Desktop and Web are "
                    + "only clients, and sessions keep the engine they were "
                    + "created with. Changing the default affects newly "
                    + "created sessions only."
            )
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)

            Text("ghostline (recommended)").font(WarrenTypography.body).foregroundStyle(tokens.foreground)
            Text(
                "Server-side libghostty-vt snapshots match the client exactly; "
                    + "a detached server keeps sessions alive across daemon "
                    + "upgrades; input reaches the PTY verbatim."
            )
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)

            Text("tmux").font(WarrenTypography.body).foregroundStyle(tokens.foreground)
            Text(
                "Mature and battle-tested, but adds a middle layer that "
                    + "re-parses and re-renders output, translates input keys, "
                    + "and can misalign colored history on replay."
            )
            .font(WarrenTypography.supporting)
            .foregroundStyle(tokens.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        section: SettingsSection,
        tokens: WarrenColorTokens,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xlarge) {
            VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                Text(title).font(WarrenTypography.pageTitle)
                Text(section.detail)
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
            }
            .padding(.bottom, WarrenSpacing.small)
            content()
        }
    }

    private var normalizedFont: TerminalFontPreference {
        TerminalFontPreference(family: fontFamily, size: fontSize)
    }

    private var preview: String {
        "Preview: " + TerminalDisplayTitleTemplate(rawValue: titleTemplate).render(.init(
            session: "Claude", command: "claude", directory: "/Users/me/Workspace/warren",
            workspace: "warren", branch: "main", host: "MacBook Pro", user: "me", os: "macOS"
        ))
    }
}

private struct InstalledIDE: Identifiable {
    let id: String
    let name: String
    let path: String
    let icon: NSImage
}
