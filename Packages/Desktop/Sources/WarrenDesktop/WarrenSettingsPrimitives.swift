import AppKit
import SwiftUI
import WarrenDesignSystem

// MARK: - Palette

/// The Settings page's own surface colors, taken from the redesign spec.
///
/// Settings deliberately does not follow the window's glass material: the spec
/// keeps it opaque so a group box reads as one object. The values are therefore
/// resolved per appearance and never blended, which also keeps the colored
/// navigation tiles legible on both grounds.
struct WarrenSettingsPalette {
    let windowBackdrop: Color
    let card: Color
    let cardBorder: Color
    let box: Color
    let boxBorder: Color
    let rowDivider: Color

    let ink: Color
    let inkBody: Color
    let inkQuiet: Color
    let inkFaint: Color
    let meta: Color
    let icon: Color

    let hover: Color
    let selected: Color

    let controlFill: Color
    let controlBorder: Color
    let controlSelected: Color
    let controlSelectedBorder: Color

    let field: Color
    let fieldBorder: Color
    let fieldFocusBorder: Color
    let fieldErrorBorder: Color

    let primaryFill: Color
    let primaryText: Color
    let secondaryFill: Color
    let secondaryBorder: Color
    let secondaryText: Color
    let plainText: Color

    let dangerText: Color
    let errorText: Color
    let success: Color
    let warning: Color
    let info: Color
    let focusRing: Color

    let switchOffTrack: Color
    let switchOffBorder: Color
    let switchOffKnob: Color
    let switchOnTrack: Color
    let switchOnKnob: Color

    static func resolved(for colorScheme: ColorScheme) -> Self {
        colorScheme == .light ? .light : .dark
    }

    /// Every value is derived from the shared tokens, so Settings cannot drift
    /// from the app it lives in. The design asks for exactly that: the page's
    /// own palette was a second definition of the same greys.
    static let dark = Self.make(from: .dark, isLight: false)
    static let light = Self.make(from: .light, isLight: true)

    static func make(from tokens: WarrenColorTokens, isLight: Bool) -> Self {
        let ink = tokens.foreground
        return Self(
            windowBackdrop: tokens.windowBackdrop,
            card: tokens.background,
            cardBorder: tokens.border,
            box: tokens.chromeSurface,
            boxBorder: tokens.border,
            rowDivider: ink.opacity(0.06),
            ink: ink,
            // The design's #D4D4D4 body ink on #EDEDED, as a share of the ink so
            // it steps the same way in the light appearance.
            inkBody: ink.opacity(isLight ? 1 : 0.89),
            inkQuiet: tokens.sidebarTextBase,
            // The sidebar's section tier, from the same base: faded from
            // `mutedForeground` it fell to 2.6:1 on paper, while the sidebar's
            // ladder keeps it near 3.1:1 in both appearances.
            inkFaint: tokens.sidebarTextBase.opacity(WarrenSidebarTextWeight.section),
            meta: tokens.mutedForeground.opacity(0.72),
            icon: tokens.mutedForeground,
            hover: tokens.fillHover,
            selected: tokens.fillSelected,
            controlFill: tokens.chromeSurface,
            controlBorder: tokens.border,
            // A wash over the control rather than the control's own fill, so
            // a selected segment or a hovered inline button is a visible step
            // above the box instead of the same grey with a hairline.
            controlSelected: tokens.fillSelected,
            controlSelectedBorder: tokens.ring,
            field: tokens.inputSurface,
            fieldBorder: tokens.border,
            // Keyboard focus is the one accent ring everywhere in the app; the
            // passive `ring` grey nearly vanished against paper.
            fieldFocusBorder: tokens.focusRing,
            fieldErrorBorder: tokens.destructive.opacity(0.6),
            // The primary is the inverted ink in both appearances.
            primaryFill: ink,
            primaryText: tokens.background,
            secondaryFill: tokens.inputSurface,
            secondaryBorder: tokens.border,
            secondaryText: ink.opacity(isLight ? 1 : 0.89),
            plainText: tokens.mutedForeground,
            dangerText: tokens.destructive,
            errorText: tokens.destructive,
            success: tokens.success,
            warning: tokens.warning,
            info: tokens.info,
            focusRing: tokens.focusRing,
            // Off has to read as a control, not as a hole in the card: a
            // visible track and a knob nearly as bright as the on state's.
            switchOffTrack: ink.opacity(isLight ? 0.14 : 0.16),
            switchOffBorder: ink.opacity(isLight ? 0.20 : 0.22),
            switchOffKnob: isLight ? tokens.background : ink.opacity(0.78),
            switchOnTrack: ink,
            switchOnKnob: tokens.background
        )
    }
}

// MARK: - Status

enum WarrenStatusTone: Equatable {
    case ok
    case warning
    case failed
    case busy
}

/// The 7pt corner dot. A status is a dot before it is a word.
///
/// The dot is centred on its own frame; the caller places it on the corner it
/// belongs to. Busy work pulses through `WarrenStatusIndicator`, whose ring is
/// driven by Core Animation and follows Reduce Motion as it changes, rather
/// than a SwiftUI `repeatForever` that redraws the whole hosting view.
struct WarrenSettingsStatusDot: View {
    let tone: WarrenStatusTone
    var ring: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        ZStack {
            Circle()
                .fill(ring)
                .frame(width: 10, height: 10)
            switch tone {
            case .busy:
                WarrenStatusIndicator(
                    color: palette.inkQuiet,
                    isActive: true,
                    size: 7,
                    intensity: .quiet,
                    accessibilityLabel: "Busy"
                )
            case .ok:
                Circle().fill(palette.success).frame(width: 7, height: 7)
            case .warning:
                Circle().fill(palette.warning).frame(width: 7, height: 7)
            case .failed:
                Circle().fill(palette.dangerText).frame(width: 7, height: 7)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

/// A status read-out placed after an action: one line saying what happened.
struct WarrenSettingsStatusLine: View {
    let tone: WarrenStatusTone
    let text: String
    var isError = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        HStack(spacing: 6) {
            if tone != .busy {
                Circle()
                    .fill(dotColor(palette))
                    .frame(width: 7, height: 7)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(isError ? palette.errorText : palette.inkQuiet)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dotColor(_ palette: WarrenSettingsPalette) -> Color {
        switch tone {
        case .ok: palette.success
        case .warning: palette.warning
        case .failed: palette.dangerText
        case .busy: palette.inkQuiet
        }
    }
}

// MARK: - Metrics

/// Shared sizes, so a control in one group lines up with its peers in the
/// next instead of each page picking its own width.
enum WarrenSettingsMetrics {
    /// Every text field that sits at the end of a row.
    static let fieldWidth: CGFloat = 320
}

// MARK: - Group

/// One rounded box of settings rows, with an optional noun heading above it and
/// an optional footnote below it.
///
/// The box holds no nested boxes: a group is the unit. Rows inside are
/// separated by a full-bleed hairline.
struct WarrenSettingsGroup<Content: View>: View {
    private let title: String?
    private let accessory: String?
    private let footnote: String?
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        _ title: String? = nil,
        accessory: String? = nil,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = accessory
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // A step above row text, so a group reads as a section
                    // heading rather than as one more caption among the rows.
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.inkBody)
                    Spacer(minLength: 8)
                    if let accessory {
                        Text(accessory)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.meta)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.box)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.boxBorder, lineWidth: 1)
            }

            if let footnote {
                Text(footnote)
                    .font(.system(size: 11.5))
                    .lineSpacing(3)
                    .foregroundStyle(palette.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }
        }
    }
}

/// A full-bleed hairline between two rows of a group.
struct WarrenSettingsRowDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(WarrenSettingsPalette.resolved(for: colorScheme).rowDivider)
            .frame(height: 1)
    }
}

// MARK: - Row

/// A settings row: a title and an optional explanation on the left, one control
/// on the right.
struct WarrenSettingsRow<Control: View>: View {
    private let title: String
    private let description: String
    private let leading: AnyView?
    private let control: Control
    private let isEnabled: Bool
    private let onRowTap: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    init(
        _ title: String,
        description: String? = nil,
        isEnabled: Bool = true,
        onRowTap: (() -> Void)? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description ?? ""
        self.leading = nil
        self.isEnabled = isEnabled
        self.onRowTap = onRowTap
        self.control = control()
    }

    init<Leading: View>(
        _ title: String,
        description: String? = nil,
        leading: Leading,
        isEnabled: Bool = true,
        onRowTap: (() -> Void)? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description ?? ""
        self.leading = AnyView(leading)
        self.isEnabled = isEnabled
        self.onRowTap = onRowTap
        self.control = control()
    }

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        HStack(alignment: .center, spacing: 16) {
            if let leading {
                leading
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.inkBody)
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11.5))
                        .lineSpacing(2)
                        .foregroundStyle(palette.meta)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onRowTap?() }

            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .opacity(isEnabled ? 1 : 0.42)
        .allowsHitTesting(isEnabled)
    }
}

/// A row whose whole title area toggles the switch, as the spec requires.
struct WarrenSettingsToggleRow: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool
    var isEnabled: Bool = true
    var accessibilityID: String? = nil

    var body: some View {
        WarrenSettingsRow(
            title,
            description: description,
            isEnabled: isEnabled,
            onRowTap: { isOn.toggle() }
        ) {
            WarrenSettingsSwitch(isOn: $isOn, isEnabled: isEnabled)
                .accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityID ?? "")
                .warrenSemanticElement(
                    id: accessibilityID ?? title,
                    role: .button,
                    label: title,
                    value: isOn ? "On" : "Off",
                    isEnabled: isEnabled,
                    isSelected: isOn,
                    action: { isOn.toggle() }
                )
        }
    }
}

// MARK: - Switch

struct WarrenSettingsSwitch: View {
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(WarrenSettingsSwitchStyle())
            .disabled(!isEnabled)
    }
}

struct WarrenSettingsSwitchStyle: ToggleStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? palette.switchOnTrack : palette.switchOffTrack)
                    .overlay {
                        if !configuration.isOn {
                            Capsule().strokeBorder(palette.switchOffBorder, lineWidth: 1)
                        }
                    }
                    .frame(width: 30, height: 18)
                Circle()
                    .fill(configuration.isOn ? palette.switchOnKnob : palette.switchOffKnob)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78),
                value: configuration.isOn
            )
        }
        .buttonStyle(.plain)
        // A locked switch does not fade itself: the row it sits in fades as
        // a whole, once, at 0.42, so the switch still shows which way it is
        // set instead of nearly vanishing under a second fade.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Segmented

/// Two or three mutually exclusive options, applied immediately.
struct WarrenSettingsSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var accessibilityID: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segment(option.value, label: option.label, palette: palette)
            }
        }
        .padding(2)
        .background(palette.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.controlBorder, lineWidth: 1)
        }
        // The selection moves at once: the spec keeps a segmented control
        // still, with no plate sliding between segments.
        .accessibilityIdentifier(accessibilityID ?? "")
    }

    private func segment(_ value: Value, label: String, palette: WarrenSettingsPalette) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? palette.ink : palette.inkQuiet)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.controlSelected)
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(palette.controlSelectedBorder, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Picker

/// A drop-down that shows the current value and opens the shared floating
/// surface with a checkmark on the current row.
///
/// The trigger is a real button, so it sits in the key-view loop and
/// VoiceOver can press it; the list answers the arrow keys and Return, and a
/// choice closes it, as every menu in the app does.
struct WarrenSettingsPicker<Value: Hashable>: View {
    let label: String
    let value: String
    let options: [(value: Value, label: String, detail: String?)]
    @Binding var selection: Value
    var monospaced = false
    var minWidth: CGFloat = 120
    var maxWidth: CGFloat = 240
    var sourceNote: String? = nil
    var accessibilityID: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @State private var isPresented = false

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(value)
                    .font(monospaced
                        ? .system(size: 12, design: .monospaced)
                        : .system(size: 12.5))
                    .foregroundStyle(palette.inkBody)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.inkFaint)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(minWidth: minWidth, maxWidth: maxWidth, minHeight: 28)
            .background(palette.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isFocused ? palette.focusRing : palette.controlBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .help(value)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier(accessibilityID ?? "")
        .warrenMenuPanel(isPresented: $isPresented, width: WarrenDesktopMenuMetrics.menuWidth) {
            WarrenSettingsPickerPanel(
                options: options,
                selection: $selection,
                sourceNote: sourceNote,
                onChoose: { isPresented = false }
            )
        }
    }
}

/// The picker's list: the menu's check rows, with one highlighted row that
/// the pointer and the arrow keys share.
private struct WarrenSettingsPickerPanel<Value: Hashable>: View {
    let options: [(value: Value, label: String, detail: String?)]
    @Binding var selection: Value
    let sourceNote: String?
    let onChoose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hot: Int?

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let isChecked = selection == option.value
                Button {
                    choose(index)
                } label: {
                    HStack(spacing: WarrenDesktopMenuMetrics.checkSpacing) {
                        WarrenDesktopMenuCheckColumn(isChecked: isChecked)
                        Text(option.label)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.inkBody)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let detail = option.detail {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.meta)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, WarrenDesktopMenuMetrics.rowHorizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: WarrenDesktopMenuMetrics.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WarrenDesktopMenuRowStyle(forceHover: hot == index))
                .onHover { inside in
                    hot = inside ? index : (hot == index ? nil : hot)
                }
                .accessibilityAddTraits(isChecked ? .isSelected : [])
            }

            if let sourceNote {
                Text(sourceNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.meta)
                    .padding(.horizontal, WarrenDesktopMenuMetrics.rowHorizontalPadding)
                    .padding(.top, 5)
            }
        }
        .overlay { WarrenDesktopKeyCatcher(onKey: handle) }
    }

    private func choose(_ index: Int) {
        guard options.indices.contains(index) else { return }
        selection = options[index].value
        onChoose()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard !options.isEmpty else { return false }
        switch event.keyCode {
        case 125: // down
            hot = ((hot ?? currentIndex ?? -1) + 1) % options.count
        case 126: // up
            hot = ((hot ?? currentIndex ?? options.count) - 1 + options.count) % options.count
        case 115: // home
            hot = 0
        case 119: // end
            hot = options.count - 1
        case 36, 76: // return
            guard let hot else { return true }
            choose(hot)
        default:
            return false
        }
        return true
    }

    /// The row the list opened on, so the first arrow moves from the value
    /// already chosen rather than from the top.
    private var currentIndex: Int? {
        options.firstIndex { $0.value == selection }
    }
}

// MARK: - Stepper

struct WarrenSettingsStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String? = nil
    var display: (Double) -> String
    var accessibilityID: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        HStack(spacing: 0) {
            stepButton(symbol: "minus", enabled: value > range.lowerBound, palette: palette) {
                value = max(range.lowerBound, value - step)
            }
            Rectangle().fill(palette.controlBorder).frame(width: 1, height: 28)
            HStack(spacing: 2) {
                Text(display(value))
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(palette.inkBody)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.inkFaint)
                }
            }
            .frame(minWidth: 44)
            .frame(height: 28)
            Rectangle().fill(palette.controlBorder).frame(width: 1, height: 28)
            stepButton(symbol: "plus", enabled: value < range.upperBound, palette: palette) {
                value = min(range.upperBound, value + step)
            }
        }
        .background(palette.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(palette.controlBorder, lineWidth: 1)
        }
        .accessibilityIdentifier(accessibilityID ?? "")
    }

    private func stepButton(
        symbol: String,
        enabled: Bool,
        palette: WarrenSettingsPalette,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.inkQuiet)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .accessibilityLabel(symbol == "minus" ? "Decrease" : "Increase")
    }
}

// MARK: - Input

/// A text field whose machine-read values render in the monospaced face.
struct WarrenSettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var monospaced = false
    var width: CGFloat? = nil
    var errorMessage: String? = nil
    var isEnabled = true
    var onSubmit: (() -> Void)? = nil
    var accessibilityID: String? = nil

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 4) {
            field(palette: palette)
                .frame(width: width)
                .frame(minHeight: 28)
                // The plain field only takes clicks on its line of text, so a
                // click on the box's padding used to do nothing at all. The
                // catcher sits behind the field, so clicks on the text still
                // place the caret.
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isFocused = true }
                }
                .background(palette.field)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(borderColor(palette), lineWidth: 1)
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.errorText)
            }
        }
        .opacity(isEnabled ? 1 : 0.42)
        .allowsHitTesting(isEnabled)
        .accessibilityIdentifier(accessibilityID ?? "")
    }

    @ViewBuilder
    private func field(palette: WarrenSettingsPalette) -> some View {
        let font: Font = monospaced
            ? .system(size: 12, design: .monospaced)
            : .system(size: 12.5)
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(font)
        .foregroundStyle(palette.inkBody)
        .focused($isFocused)
        .onSubmit { onSubmit?() }
        .padding(.horizontal, 9)
    }

    private func borderColor(_ palette: WarrenSettingsPalette) -> Color {
        if errorMessage != nil { return palette.fieldErrorBorder }
        if isFocused { return palette.fieldFocusBorder }
        return palette.fieldBorder
    }
}

/// A read-only machine value with a copy affordance.
struct WarrenSettingsReadout: View {
    let value: String
    var copyable = false
    var maxWidth: CGFloat = 320

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var copyFeedback = WarrenCopyFeedback.shared

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        let copied = copyFeedback.confirms("settings.readout.\(value)")
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(palette.inkBody)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxWidth, alignment: .trailing)
                .help(value)
            if copyable {
                WarrenSettingsInlineButton(
                    systemImage: copied ? "checkmark" : "doc.on.doc",
                    label: copied ? "Copied" : "Copy"
                ) {
                    copyFeedback.copy(value, confirmingIn: "settings.readout.\(value)")
                }
            }
        }
    }
}

// MARK: - Buttons

enum WarrenSettingsButtonKind {
    case primary
    case secondary
    case plain
    case danger
}

/// Settings' buttons are the app's buttons: a primary, a secondary and a
/// destructive action look and behave here exactly as they do in a dialog.
/// Only the text-only `plain` kind, which the shared styles have no peer
/// for, draws itself.
struct WarrenSettingsButtonStyle: ButtonStyle {
    let kind: WarrenSettingsButtonKind

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        switch kind {
        case .primary:
            WarrenPrimaryButtonStyle().makeBody(configuration: configuration)
        case .secondary:
            WarrenSecondaryButtonStyle().makeBody(configuration: configuration)
        case .danger:
            WarrenDestructiveButtonStyle().makeBody(configuration: configuration)
        case .plain:
            WarrenSettingsPlainButtonBody(configuration: configuration)
        }
    }
}

/// A text-only action: quiet ink, a wash on hover, a deeper wash while
/// pressed, and the accent ring while it holds keyboard focus.
private struct WarrenSettingsPlainButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
        let hot = hovering && isEnabled
        configuration.label
            .font(WarrenTypography.body)
            .foregroundStyle(hot ? palette.ink : palette.plainText)
            .padding(.horizontal, 8)
            .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
            .background {
                shape.fill(
                    configuration.isPressed && isEnabled
                        ? tokens.fillSelected
                        : (hot ? tokens.fillHover : .clear)
                )
            }
            .overlay {
                if isFocused, isEnabled {
                    shape.strokeBorder(tokens.focusRing, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { hovering = $0 }
    }
}

/// A small icon-only action that stays inside its row.
struct WarrenSettingsInlineButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(hovering || isActive ? palette.ink : palette.inkQuiet)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? palette.controlSelected : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Width

extension View {
    /// Writes this view's laid-out width into `width`, so a layout can choose
    /// its columns from the room it actually has instead of a guessed constant.
    ///
    /// Only for views whose width comes from their container (a flexible
    /// frame), never from their own content; otherwise the measurement feeds
    /// back into the layout it measures.
    func warrenMeasureWidth(_ width: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width.wrappedValue = proxy.size.width }
                    .onChange(of: proxy.size.width) { width.wrappedValue = $0 }
            }
        }
    }
}

// MARK: - List row

/// One entry in a list of like things: presets, devices, editors.
struct WarrenSettingsListRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    var isDimmed = false
    let leading: Leading
    let trailing: Trailing

    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        subtitle: String? = nil,
        isDimmed: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isDimmed = isDimmed
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        HStack(alignment: .center, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isDimmed ? palette.inkFaint : palette.inkBody)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.meta)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: subtitle == nil ? 42 : 48)
        .opacity(isDimmed ? 0.75 : 1)
    }
}

/// The empty state of a list: one quiet line.
struct WarrenSettingsEmptyRow: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(WarrenSettingsPalette.resolved(for: colorScheme).meta)
            .padding(.horizontal, 14)
            .frame(minHeight: 44, alignment: .leading)
    }
}

// MARK: - Reveal

/// Content that a row's action produces, inserted directly under the trigger
/// rather than in a sheet.
/// A short-lived credential's remaining life, as a thin bar under its text.
/// An invite and a pairing PIN both expire on their own, so the row shows how
/// long is left instead of only a sentence.
struct WarrenSettingsCountdownBar: View {
    let expiresAt: Date?
    let total: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(
                0,
                expiresAt.map { $0.timeIntervalSince(context.date) } ?? Double(total)
            )
            let fraction = total > 0 ? min(1, remaining / Double(total)) : 0
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.controlFill)
                    Capsule()
                        .fill(palette.ink.opacity(0.45))
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)
        }
        .accessibilityHidden(true)
    }
}

struct WarrenSettingsReveal<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Token chip

/// A fixed snippet that inserts a token into a template field.
struct WarrenSettingsTokenChip: View {
    let token: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            WarrenDesktopCodeChip(text: token)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Insert \(token)")
    }
}

// MARK: - Keycap

struct WarrenSettingsKeycaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                WarrenSettingsKeycap(key: key)
            }
        }
        .accessibilityHidden(true)
    }
}

struct WarrenSettingsKeycap: View {
    let key: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenSettingsPalette.resolved(for: colorScheme)
        Text(key)
            .font(.system(size: 11))
            .foregroundStyle(palette.inkQuiet)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(palette.controlFill)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(palette.controlBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
