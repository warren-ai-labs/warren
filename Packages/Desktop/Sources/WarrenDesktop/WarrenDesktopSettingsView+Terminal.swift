import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

extension WarrenDesktopSettingsView {
    // MARK: - Terminal

    func terminalSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Font") {
                WarrenSettingsRow("Family") {
                    WarrenSettingsPicker(
                        label: "Font family",
                        value: fontFamily,
                        options: monospacedFamilies.map { ($0, $0, nil) },
                        selection: $fontFamily,
                        monospaced: true,
                        sourceNote: "Monospaced fonts on this Mac",
                        accessibilityID: "settings.terminal.font-family"
                    )
                }

                WarrenSettingsRowDivider()

                WarrenSettingsRow("Size") {
                    WarrenSettingsStepper(
                        value: $fontSize,
                        range: 9...24,
                        unit: "pt",
                        display: { String(Int($0.rounded())) },
                        accessibilityID: "settings.terminal.font-size"
                    )
                }

                WarrenSettingsRowDivider()

                TerminalFontPreview(preference: normalizedFont, palette: palette, title: preview)
            }

            WarrenSettingsGroup("Pane title", accessory: "The line under each pane's header") {
                VStack(alignment: .leading, spacing: 6) {
                    WarrenSettingsTextField(
                        placeholder: TerminalDisplayTitleTemplate.defaultValue.rawValue,
                        text: $titleTemplate,
                        monospaced: true,
                        accessibilityID: "settings.terminal.title-template"
                    )
                    HStack(spacing: 6) {
                        Text("↳")
                            .font(WarrenTypography.codeSmall)
                            .foregroundStyle(palette.inkFaint)
                            .accessibilityHidden(true)
                        Text(renderedTitle)
                            .font(WarrenTypography.codeSmall)
                            .foregroundStyle(palette.meta)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .accessibilityLabel("Preview \(renderedTitle)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                WarrenSettingsRowDivider()

                FlowingChips(
                    tokens: TerminalDisplayTitleTemplate.placeholders.map { ($0.token, $0.description) },
                    palette: palette,
                    onInsert: insertPlaceholder
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            Button("Restore Terminal Defaults") {
                titleTemplate = TerminalDisplayTitleTemplate.defaultValue.rawValue
                fontFamily = TerminalFontPreference.defaultFamily
                fontSize = TerminalFontPreference.defaultSize
            }
            .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
            .padding(.leading, 14)
            .accessibilityIdentifier("settings.restore-defaults")

            crossLink(
                "The engine that runs new Sessions is a Host setting, in",
                to: .terminalRuntime,
                palette: palette,
                identifier: "settings.terminal.goto-runtime"
            )
        }
    }

    func insertPlaceholder(_ token: String) {
        if !titleTemplate.isEmpty, !titleTemplate.hasSuffix(" ") { titleTemplate += " " }
        titleTemplate += token
    }

    // MARK: - Launch commands

    func presetsSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Agent interface") {
                WarrenSettingsRow(
                    "Launch As",
                    description: "Claude, Codex and OpenCode can run as their CLI or as a Chat over ACP. Ask each time shows both under the clicked preset."
                ) {
                    WarrenSettingsSegmented(
                        options: WarrenAgentInterface.allCases.map { ($0, $0.displayName) },
                        selection: agentInterfaceSelection,
                        accessibilityID: "settings.agent-interface.picker"
                    )
                }
            }

            WarrenSettingsGroup(
                "Presets",
                accessory: "Order here is the order in the + menu",
                footnote: "Commands are typed into a plain shell after it opens, so quitting an agent with Ctrl-C or Ctrl-D keeps the tab alive. Leave Shell empty for a bare terminal. Hidden presets keep their command. Click a row to edit it."
            ) {
                ForEach(Array(orderedPresets.enumerated()), id: \.element.id) { index, preset in
                    if index > 0 { WarrenSettingsRowDivider() }
                    mergedPresetRow(preset, index: index, palette: palette)
                }
            }
        }
    }

    /// One row per preset, carrying its order, its visibility, and its command:
    /// the two old lists read as the same list to a user, so they are one now.
    /// Clicking the row (outside its controls) opens the command editor under it.
    func mergedPresetRow(
        _ preset: WarrenDesktopSessionPreset,
        index: Int,
        palette: WarrenSettingsPalette
    ) -> some View {
        let isVisible = !WarrenDesktopSessionPreset.normalizedHidden(hiddenPresets).contains(preset.id)
        let isEditing = editingPresetID == preset.id
        let isEditable = preset.request.kind != .browser && preset.request.kind != .custom
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    guard isEditable else { return }
                    editingPresetID = isEditing ? nil : preset.id
                } label: {
                    HStack(spacing: 10) {
                        // The same app icon the + menu, the Tab and the tree
                        // draw for this preset's Sessions.
                        WarrenDesktopSessionKindBadge(kind: preset.request.kind, size: 18)
                            .opacity(isVisible ? 1 : 0.45)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.presetBarTitle)
                                .font(WarrenTypography.settingsBodyEmphasis)
                                .foregroundStyle(isVisible ? palette.inkBody : palette.inkFaint)
                            Text(presetCommandSummary(preset))
                                .font(WarrenTypography.codeSmall)
                                .foregroundStyle(palette.meta)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .focusable()
                .focused($focusedPresetID, equals: preset.id)

                HStack(spacing: 4) {
                    presetMoveButton(preset: preset, direction: -1, symbolName: "arrow.up", disabled: index == 0)
                    presetMoveButton(preset: preset, direction: 1, symbolName: "arrow.down", disabled: index == orderedPresets.count - 1)
                }
                WarrenSettingsSwitch(isOn: presetVisibilityBinding(for: preset))
                    .accessibilityLabel("Show \(preset.presetBarTitle)")
                    .accessibilityIdentifier("settings.preset-visibility.\(preset.id)")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(
                draggedPresetID == preset.id ? palette.selected : Color.clear,
                in: RoundedRectangle(cornerRadius: WarrenRadius.row, style: .continuous)
            )
            .shadow(
                color: .black.opacity(draggedPresetID == preset.id ? 0.45 : 0),
                radius: 10,
                y: 8
            )
            .draggable(preset.id) {
                Text(preset.presetBarTitle)
                    .font(WarrenTypography.body)
                    .padding(6)
                    .background(palette.card)
                    .onAppear { draggedPresetID = preset.id }
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let dragged = ids.first, dragged != preset.id else { return false }
                presetOrder = WarrenDesktopSessionPreset.moving(
                    dragged,
                    before: preset.id,
                    in: presetOrder
                )
                return true
            }
            .overlay(alignment: .leading) {
                // ⌥↑ / ⌥↓ belong to the row the keyboard is on. The buttons carry
                // the shortcuts and draw nothing.
                if focusedPresetID == preset.id {
                    HStack(spacing: 0) {
                        Button("") {
                            presetOrder = WarrenDesktopSessionPreset.moving(
                                preset.id,
                                by: -1,
                                in: presetOrder
                            )
                        }
                        .keyboardShortcut(.upArrow, modifiers: .option)
                        Button("") {
                            presetOrder = WarrenDesktopSessionPreset.moving(
                                preset.id,
                                by: 1,
                                in: presetOrder
                            )
                        }
                        .keyboardShortcut(.downArrow, modifiers: .option)
                    }
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            }

            if isEditing {
                WarrenSettingsTextField(
                    placeholder: commandPlaceholder(for: preset),
                    text: commandBinding(for: preset),
                    monospaced: true,
                    onSubmit: { editingPresetID = nil },
                    accessibilityID: "settings.preset-command.\(preset.id)"
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .animation(WarrenMotion.selection(reduceMotion: reduceMotion), value: isEditing)
        .animation(WarrenMotion.selection(reduceMotion: reduceMotion), value: draggedPresetID)
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            draggedPresetID = nil
            return false
        }
    }

    func presetCommandSummary(_ preset: WarrenDesktopSessionPreset) -> String {
        if preset.request.kind == .browser { return "Launched by the Host" }
        let command = commandBinding(for: preset).wrappedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? "Empty: bare terminal" : command
    }

    func commandBinding(for preset: WarrenDesktopSessionPreset) -> Binding<String> {
        switch preset.request.kind {
        case .shell: return $shellCommand
        case .claude: return $claudeCommand
        case .codex: return $codexCommand
        case .opencode: return $opencodeCommand
        case .pi: return $piCommand
        case .qoder: return $qoderCommand
        case .antigravity: return $antigravityCommand
        case .trae: return $traeCommand
        case .custom, .browser: return .constant("")
        }
    }

    func commandPlaceholder(for preset: WarrenDesktopSessionPreset) -> String {
        switch preset.request.kind {
        case .shell: return "Empty: bare terminal"
        case .claude: return "claude"
        case .codex: return "codex --dangerously-bypass-hook-trust"
        case .opencode: return "opencode"
        case .pi: return "pi"
        case .qoder: return "qoder"
        case .antigravity: return "agy"
        case .trae: return "trae-cli interactive"
        case .custom, .browser: return ""
        }
    }

    func presetMoveButton(
        preset: WarrenDesktopSessionPreset,
        direction: Int,
        symbolName: String,
        disabled: Bool
    ) -> some View {
        let directionLabel = direction < 0 ? "up" : "down"
        return Button {
            presetOrder = WarrenDesktopSessionPreset.moving(preset.id, by: direction, in: presetOrder)
        } label: {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("Move \(preset.presetBarTitle) \(directionLabel)")
        .accessibilityIdentifier("settings.preset-order.\(preset.id).\(directionLabel)")
    }

    // MARK: - Editors

    /// The single-choice column: which editor Open in Editor uses. Empty for
    /// the rows that are not it, so every name keeps the same column.
    func editorCheck(_ isSelected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WarrenSettingsPalette.resolved(for: colorScheme).ink)
            .frame(width: 14)
            .opacity(isSelected ? 1 : 0)
            .accessibilityHidden(true)
    }

    func externalIDEsSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Embedded editor") {
                WarrenSettingsToggleRow(
                    title: "Open Embedded Editor by Default",
                    description: "The IDE button opens it directly instead of showing the picker.",
                    isOn: $embeddedEditorDefaultIDE,
                    accessibilityID: "settings.external-ides.embedded-editor-default"
                )
                WarrenSettingsRowDivider()
                WarrenSettingsToggleRow(
                    title: "Open Terminal Links in Embedded Editor",
                    description: "⌘-click a file path or file URL in the terminal to open it there.",
                    isOn: $embeddedEditorOpenLinks,
                    accessibilityID: "settings.external-ides.embedded-editor-open-links"
                )
            }

            WarrenSettingsGroup("Found on this Mac", footnote: "The list is whatever Warren detects.") {
                if installedIDEs.isEmpty {
                    WarrenSettingsEmptyRow(text: "No supported editors found on this Mac.")
                } else {
                    ForEach(Array(installedIDEs.enumerated()), id: \.element.id) { index, ide in
                        if index > 0 { WarrenSettingsRowDivider() }
                        Button { externalIDEID = ide.id } label: {
                            WarrenSettingsListRow(
                                title: ide.name,
                                subtitle: ide.path,
                                leading: {
                                    HStack(spacing: 8) {
                                        editorCheck(externalIDEID == ide.id)
                                        Image(nsImage: ide.icon)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 18, height: 18)
                                    }
                                },
                                trailing: { EmptyView() }
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(ide.name) for Open in Editor")
                        .accessibilityAddTraits(externalIDEID == ide.id ? [.isSelected] : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                WarrenSettingsGroup("Custom") {
                    if customIDEs.isEmpty {
                        WarrenSettingsEmptyRow(text: "No custom editors yet.")
                    } else {
                        ForEach(Array(customIDEs.enumerated()), id: \.element.id) { index, ide in
                            if index > 0 { WarrenSettingsRowDivider() }
                            let optionID = "custom:\(ide.id.uuidString)"
                            Button { externalIDEID = optionID } label: {
                                WarrenSettingsListRow(
                                    title: ide.name,
                                    subtitle: ide.path,
                                    leading: {
                                        HStack(spacing: 8) {
                                            editorCheck(externalIDEID == optionID)
                                            Image(nsImage: WarrenDesktopExternalIDEIcon.normalized(
                                                NSWorkspace.shared.icon(forFile: ide.path)
                                            ))
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 18, height: 18)
                                        }
                                    },
                                    trailing: {
                                        WarrenSettingsInlineButton(systemImage: "trash", label: "Remove \(ide.name)") {
                                            removeCustomIDE(ide)
                                        }
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use \(ide.name) for Open in Editor")
                            .accessibilityAddTraits(externalIDEID == optionID ? [.isSelected] : [])
                        }
                    }
                }

                Button {
                    addCustomIDE()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        Text("Add Editor…")
                    }
                }
                .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                .padding(.leading, 14)
                .accessibilityIdentifier("settings.external-ides.add")
            }
        }
        .onAppear {
            customIDEs = WarrenDesktopCustomIDEStore.load()
            // Launch Services lookups and icon renders on the main thread:
            // probe once per page lifetime rather than on every visit.
            if installedIDEs.isEmpty {
                installedIDEs = Self.probeInstalledIDEs()
            }
        }
    }

    // MARK: - Terminal runtime

    /// The two pages whose names are easy to confuse point at each other, so a
    /// reader who opened the wrong one is one click from the right one.
    func crossLink(
        _ text: String,
        to section: SettingsSection,
        palette: WarrenSettingsPalette,
        identifier: String
    ) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 6) {
                Text(text)
                    .font(WarrenTypography.caption)
                    .foregroundStyle(palette.inkQuiet)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.inkFaint)
                Text(section.rawValue)
                    .font(WarrenTypography.captionEmphasis)
                    .foregroundStyle(palette.inkBody)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .accessibilityIdentifier(identifier)
    }

    func terminalRuntimeSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            terminalRuntimeEngine(palette: palette)
            crossLink(
                "Font and title template are set per Mac in",
                to: .terminal,
                palette: palette,
                identifier: "settings.terminal-runtime.goto-terminal"
            )
        }
    }

    func terminalRuntimeEngine(palette: WarrenSettingsPalette) -> some View {
        WarrenSettingsGroup(
            "Engine",
            footnote: "Only one engine ships today, so this is a read-out instead of a picker. Sessions keep the engine they were created with; a new default applies to new sessions only."
        ) {
            WarrenSettingsRow(
                "Default Runtime",
                description: "libghostty-vt snapshots match the client exactly; the detached server keeps sessions alive across daemon upgrades."
            ) {
                Text(defaultRuntime ?? "ghostline")
                    .font(WarrenTypography.mono)
                    .foregroundStyle(palette.inkQuiet)
                    .accessibilityIdentifier("settings.terminal-runtime.picker")
            }
        }
    }

    // MARK: - AI titles

    func aiTitlesSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            // The page's first card had no heading, so it read as a stray box
            // above the Endpoint group rather than as its own section.
            WarrenSettingsGroup("Automatic titles") {
                WarrenSettingsToggleRow(
                    title: "Generate Titles Automatically",
                    description: "Codex, Claude Code, OpenCode, and Qoder name their own conversations and Warren keeps those names. This switch adds a title from the LLM below whenever an agent has not named the conversation.",
                    isOn: Binding(
                        get: { openAITitleEnabled },
                        set: { onSetOpenAISetting("openaiTitleEnabled", $0 ? "true" : "false") }
                    ),
                    accessibilityID: "settings.ai-titles.enabled"
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                WarrenSettingsGroup("Endpoint", accessory: "OpenAI-compatible") {
                    WarrenSettingsRow("Base URL") {
                        WarrenSettingsTextField(
                            placeholder: "https://api.openai.com/v1",
                            text: $openAIBaseURLDraft,
                            monospaced: true,
                            width: WarrenSettingsMetrics.fieldWidth,
                            isEnabled: !openAITestStatus.isTesting,
                            accessibilityID: "settings.ai-titles.base-url"
                        )
                    }
                    WarrenSettingsRowDivider()
                    WarrenSettingsRow("Model") {
                        WarrenSettingsTextField(
                            placeholder: "gpt-4o-mini",
                            text: $openAIModelDraft,
                            monospaced: true,
                            width: WarrenSettingsMetrics.fieldWidth,
                            isEnabled: !openAITestStatus.isTesting,
                            accessibilityID: "settings.ai-titles.model"
                        )
                    }
                    WarrenSettingsRowDivider()
                    WarrenSettingsRow("API Key", description: "Stored only on this host.") {
                        WarrenSettingsTextField(
                            placeholder: "••••••••3f2a",
                            text: $openAIKeyDraft,
                            isSecure: true,
                            monospaced: true,
                            width: WarrenSettingsMetrics.fieldWidth,
                            isEnabled: !openAITestStatus.isTesting,
                            accessibilityID: "settings.ai-titles.api-key"
                        )
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        testOpenAISettings(save: true)
                    } label: {
                        HStack(spacing: 6) {
                            if openAITestStatus.isTesting {
                                ProgressView().controlSize(.small)
                            }
                            Text(openAITestStatus.isTesting ? "Testing…" : "Save & Test")
                        }
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .primary))
                    .disabled(openAITestStatus.isTesting)
                    .accessibilityIdentifier("settings.ai-titles.save-and-test")
                    .warrenSemanticElement(
                        id: "settings.ai-titles.save-and-test",
                        role: .button,
                        label: "Save and test AI title connection",
                        isEnabled: !openAITestStatus.isTesting,
                        action: { testOpenAISettings(save: true) }
                    )

                    Button("Test") {
                        testOpenAISettings(save: false)
                    }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                    .disabled(openAITestStatus.isTesting || !hasUnsavedOpenAIDraft)
                    .accessibilityIdentifier("settings.ai-titles.test")
                    .warrenSemanticElement(
                        id: "settings.ai-titles.test",
                        role: .button,
                        label: "Test AI title connection",
                        isEnabled: !openAITestStatus.isTesting && hasUnsavedOpenAIDraft,
                        action: { testOpenAISettings(save: false) }
                    )

                    switch openAITestStatus {
                    case .idle:
                        EmptyView()
                    case .testing:
                        WarrenSettingsStatusLine(tone: .busy, text: "Testing connection…")
                    case .succeeded:
                        WarrenSettingsStatusLine(tone: .ok, text: "Connection succeeded.")
                    case .failed(let message):
                        WarrenSettingsStatusLine(tone: .failed, text: message, isError: true)
                    }
                }
                .padding(.leading, 14)
            }
        }
        .onAppear(perform: seedOpenAIFields)
    }

    func saveOpenAIField(_ key: String, _ value: String) {
        onSetOpenAISetting(key, value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func saveOpenAISettings() {
        saveOpenAIField("openaiBaseURL", openAIBaseURLDraft)
        saveOpenAIField("openaiModel", openAIModelDraft)
        let key = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            onSetOpenAISetting("openaiKey", key)
            openAIKeyDraft = ""
        }
    }

    var hasUnsavedOpenAIDraft: Bool {
        openAIBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            || openAIModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                != openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            || !openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func testOpenAISettings(save: Bool = true) {
        guard !openAITestStatus.isTesting else { return }
        if save { saveOpenAISettings() }
        let baseURL = openAIBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = openAIModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        openAITestStatus = .testing
        Task { @MainActor in
            do {
                try await onTestOpenAI(baseURL, model, key.isEmpty ? nil : key)
                openAITestStatus = .succeeded
            } catch {
                openAITestStatus = .failed(error.localizedDescription)
            }
        }
    }

    func seedOpenAIFields() {
        openAIBaseURLDraft = openAIBaseURL
        openAIModelDraft = openAIModel
        openAIKeyDraft = ""
    }

}
