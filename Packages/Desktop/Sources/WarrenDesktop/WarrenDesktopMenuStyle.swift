import SwiftUI
import WarrenDesignSystem

/// The palette of a floating menu or popover, following the adopted Workbench
/// menu spec.
///
/// The dark numbers are the spec's own. The light appearance keeps the same
/// structure with paper-appropriate greys rather than inverting the dark
/// numbers, which would leave a menu darker than the card it floats above;
/// its quiet text and glyphs take the sidebar's warm section tier, so a menu
/// opened beside the sidebar reads in the same greys.
///
/// A row's hover and press are the app's one row wash (`fillHover`,
/// `fillSelected`) with no hairline of their own, so a menu row lights the way
/// a sidebar or palette row does, and on glass the wash stays translucent
/// instead of painting an opaque plate on the material.
struct WarrenDesktopMenuPalette {
    let surface: Color
    let border: Color
    let topHighlight: Color
    let divider: Color
    let headerText: Color

    let rowText: Color
    let rowHoverText: Color
    let meta: Color
    let secondaryGlyph: Color
    let value: Color
    let chevron: Color
    let icon: Color
    let iconHover: Color
    let check: Color

    let hoverFill: Color
    let pressFill: Color
    /// The hover wash already composited over `surface`: the ring a corner
    /// dot draws on a hot row has to be opaque to cut the dot out of the
    /// glyph beneath it.
    let hotRing: Color

    let actionGlyph: Color
    let dangerText: Color
    let dangerIcon: Color

    let keycapFill: Color
    let keycapBorder: Color
    let keycapText: Color

    let tileFill: Color
    let tileBorder: Color
    let tileFailedText: Color
    let tileFailedBorder: Color

    let addText: Color

    static func resolved(for colorScheme: ColorScheme) -> Self {
        colorScheme == .light ? .light : .dark
    }

    static let dark = Self(
        surface: WarrenColorTokens.hex(0x141414),
        border: WarrenColorTokens.hex(0x262626),
        topHighlight: Color.white.opacity(0.05),
        divider: WarrenColorTokens.hex(0x222222),
        headerText: WarrenColorTokens.hex(0x6B6B6B),
        rowText: WarrenColorTokens.hex(0xD4D4D4),
        rowHoverText: WarrenColorTokens.hex(0xF5F5F5),
        meta: WarrenColorTokens.hex(0x6E6E6E),
        secondaryGlyph: WarrenColorTokens.hex(0x8A8A8A),
        value: WarrenColorTokens.hex(0x6B6B6B),
        chevron: WarrenColorTokens.hex(0x5C5C5C),
        icon: WarrenColorTokens.hex(0x8F8F8F),
        iconHover: WarrenColorTokens.hex(0xEDEDED),
        check: WarrenColorTokens.hex(0xD4D4D4),
        hoverFill: WarrenColorTokens.dark.fillHover,
        pressFill: WarrenColorTokens.dark.fillSelected,
        hotRing: WarrenColorTokens.hex(0x232323),
        actionGlyph: WarrenColorTokens.hex(0x8A8A8A),
        dangerText: WarrenColorTokens.hex(0xE57B74),
        dangerIcon: WarrenColorTokens.hex(0xE0524A),
        keycapFill: WarrenColorTokens.hex(0x1B1B1B),
        keycapBorder: WarrenColorTokens.hex(0x2C2C2C),
        keycapText: WarrenColorTokens.hex(0x8A8A8A),
        tileFill: WarrenColorTokens.hex(0x1B1B1B),
        tileBorder: WarrenColorTokens.hex(0x333333),
        tileFailedText: WarrenColorTokens.hex(0x4D4D4D),
        tileFailedBorder: WarrenColorTokens.hex(0x262626),
        addText: WarrenColorTokens.hex(0x8A8A8A)
    )

    /// Paper's quiet tier: the sidebar's section weight of its warm text
    /// base, rather than the cool neutral greys the dark spec uses.
    private static let lightQuiet = WarrenColorTokens.light.sidebarTextBase
        .opacity(WarrenSidebarTextWeight.section)

    static let light = Self(
        surface: WarrenColorTokens.hex(0xFFFFFF),
        border: WarrenColorTokens.hex(0xE0DBD6),
        topHighlight: .clear,
        divider: WarrenColorTokens.hex(0xE8E4E0),
        headerText: lightQuiet,
        rowText: WarrenColorTokens.hex(0x1C1917),
        rowHoverText: WarrenColorTokens.hex(0x000000),
        meta: lightQuiet,
        secondaryGlyph: lightQuiet,
        value: lightQuiet,
        chevron: lightQuiet,
        icon: lightQuiet,
        iconHover: WarrenColorTokens.hex(0x1C1917),
        check: WarrenColorTokens.hex(0x1C1917),
        hoverFill: WarrenColorTokens.light.fillHover,
        pressFill: WarrenColorTokens.light.fillSelected,
        hotRing: WarrenColorTokens.hex(0xF4F3F3),
        actionGlyph: lightQuiet,
        dangerText: WarrenColorTokens.hex(0xB3261E),
        dangerIcon: WarrenColorTokens.hex(0xB3261E),
        keycapFill: WarrenColorTokens.hex(0xF2EFEC),
        keycapBorder: WarrenColorTokens.hex(0xE0DBD6),
        keycapText: WarrenColorTokens.hex(0x6B6560),
        tileFill: WarrenColorTokens.hex(0xF2EFEC),
        tileBorder: WarrenColorTokens.hex(0xD2CCC6),
        tileFailedText: WarrenColorTokens.hex(0xB3ADA7),
        tileFailedBorder: WarrenColorTokens.hex(0xE0DBD6),
        addText: WarrenColorTokens.hex(0x6B6560)
    )
}

/// The one floating surface every menu and popover draws on: an opaque card
/// with a full hairline, a hairline of light along its top edge, and a single
/// soft shadow.
///
/// On glass the card is the shared raised tone (`popoverSurface`) over an
/// in-window blur, the same material the command palette and every other
/// floating surface use, instead of the opaque card painted over the blur.
struct WarrenDesktopMenuSurfaceModifier: ViewModifier {
    /// `nil` lets the surface size to its content instead of a fixed width.
    let width: CGFloat?
    /// The shadow's vertical offset. A surface that rises from the bottom of
    /// the window throws its shadow upward instead.
    var shadowY: CGFloat = 12

    @Environment(\.warrenMenuMaxHeight) private var maxHeight

    func body(content: Content) -> some View {
        content
            // The room is this surface's alone, not a nested one's.
            .environment(\.warrenMenuMaxHeight, nil)
            .modifier(WarrenDesktopMenuHeightCap(
                maxHeight: maxHeight.map { $0 - 2 * WarrenDesktopMenuMetrics.inset }
            ))
            .padding(WarrenDesktopMenuMetrics.inset)
            .frame(width: width, alignment: .leading)
            .modifier(WarrenDesktopMenuCardModifier(shadowY: shadowY))
    }
}

/// The menu surface's card alone: its fill, hairline, top highlight and
/// shadow, with no inset or height cap. A surface that is not a menu but
/// floats beside one, such as a notice toast rising to the notice center,
/// draws on this so the two read as the same material.
struct WarrenDesktopMenuCardModifier: ViewModifier {
    var shadowY: CGFloat = 12
    /// A hairline that replaces the neutral one, for a card that has to say
    /// something with its edge (an error toast).
    var border: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    func body(content: Content) -> some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let shape = RoundedRectangle(cornerRadius: WarrenDesktopMenuMetrics.radius, style: .continuous)
        content
            .background {
                if windowMaterial == .glass {
                    ZStack {
                        Rectangle().fill(.regularMaterial)
                        tokens.popoverSurface
                    }
                } else {
                    palette.surface
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(border ?? palette.border, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(palette.topHighlight)
                    .frame(height: 1)
                    .padding(.horizontal, WarrenDesktopMenuMetrics.radius)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(colorScheme == .light ? 0.12 : 0.5),
                radius: 28,
                y: shadowY
            )
    }
}

/// The tallest a menu surface may be where it is shown: the window's height
/// less the room above the surface and a margin below it. `nil` (the default)
/// leaves the surface its natural height.
private struct WarrenDesktopMenuMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var warrenMenuMaxHeight: CGFloat? {
        get { self[WarrenDesktopMenuMaxHeightKey.self] }
        set { self[WarrenDesktopMenuMaxHeightKey.self] = newValue }
    }
}

/// Keeps a menu's content inside the window. Content that fits is drawn as
/// is; only content taller than the room scrolls, so a short window never
/// pushes the bottom of a menu (the "+" menu's Launch commands row, the last
/// Hosts) past the window's edge.
struct WarrenDesktopMenuHeightCap: ViewModifier {
    let maxHeight: CGFloat?

    @State private var contentHeight: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if let maxHeight, contentHeight > maxHeight {
            ScrollView(.vertical) {
                measured(content)
            }
            .frame(height: max(maxHeight, 0))
        } else {
            measured(content)
        }
    }

    /// The content at its natural height, reporting it.
    private func measured(_ content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { contentHeight = $0 }
                }
            }
    }
}

public extension View {
    /// Wraps content in the shared floating menu surface at `width`.
    func warrenMenuSurface(width: CGFloat?, shadowY: CGFloat = 12) -> AnyView {
        AnyView(modifier(WarrenDesktopMenuSurfaceModifier(width: width, shadowY: shadowY)))
    }
}

/// The fill of one menu row in its resting, hovered, pressed or disabled
/// state.
///
/// A list that drives its rows from the keyboard owns the highlight: it
/// passes `forceHover` for every row, and the row then draws exactly that,
/// never its own pointer hover as well, so the pointer and the arrow keys
/// share one highlighted row instead of lighting two. Left `nil`, the row
/// follows the pointer itself.
struct WarrenDesktopMenuRowStyle: ButtonStyle {
    var danger = false
    var forceHover: Bool? = nil
    var cornerRadius: CGFloat = WarrenDesktopMenuMetrics.rowRadius

    func makeBody(configuration: Configuration) -> some View {
        Row(
            configuration: configuration,
            danger: danger,
            forceHover: forceHover,
            cornerRadius: cornerRadius
        )
    }

    private struct Row: View {
        let configuration: Configuration
        let danger: Bool
        let forceHover: Bool?
        let cornerRadius: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let pressed = configuration.isPressed
            let disabled = !isEnabled
            let hot = (forceHover ?? isHovered) && !disabled
            configuration.label
                .background {
                    shape.fill(
                        disabled ? .clear : (pressed ? palette.pressFill : (hot ? palette.hoverFill : .clear))
                    )
                }
                .opacity(disabled ? 0.42 : 1)
                .contentShape(shape)
                .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: hot)
                .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: pressed)
                .onHover { isHovered = $0 }
        }
    }
}

/// A keyboard shortcut as one keycap per key.
struct WarrenDesktopMenuKeycaps: View {
    let keys: String

    var body: some View {
        HStack(spacing: WarrenDesktopMenuMetrics.keycapSpacing) {
            ForEach(Array(keys.map(String.init).enumerated()), id: \.offset) { _, key in
                WarrenDesktopMenuKeycap(key: key)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WarrenDesktopMenuKeycap: View {
    let key: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        Text(key)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(palette.keycapText)
            .padding(.horizontal, WarrenDesktopMenuMetrics.keycapPadding)
            .frame(minWidth: WarrenDesktopMenuMetrics.keycapMinWidth, minHeight: WarrenDesktopMenuMetrics.keycapHeight)
            .background {
                RoundedRectangle(cornerRadius: WarrenDesktopMenuMetrics.keycapRadius, style: .continuous)
                    .fill(palette.keycapFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: WarrenDesktopMenuMetrics.keycapRadius, style: .continuous)
                    .strokeBorder(palette.keycapBorder, lineWidth: 1)
            }
    }
}

/// The chevron that says a row has a submenu or a drill-in page.
struct WarrenDesktopMenuChevron: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(WarrenDesktopMenuPalette.resolved(for: colorScheme).chevron)
            .accessibilityHidden(true)
    }
}

/// The current item of a single-choice list: a column of its own at the row's
/// leading edge, so names stay aligned whether or not the row is checked.
struct WarrenDesktopMenuCheckColumn: View {
    let isChecked: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WarrenDesktopMenuPalette.resolved(for: colorScheme).check)
            .opacity(isChecked ? 1 : 0)
            .frame(width: WarrenDesktopMenuMetrics.checkColumnWidth, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A row's leading glyph: an SF Symbol, tinted by the row's state.
struct WarrenDesktopMenuRowIcon: View {
    let systemImage: String
    var isHot = false
    var danger = false
    var status: WarrenDesktopMenuStatus? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(danger ? palette.dangerIcon : (isHot ? palette.iconHover : palette.icon))
            .frame(width: WarrenDesktopMenuMetrics.glyphSlot, height: WarrenDesktopMenuMetrics.glyphSlot)
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    WarrenDesktopMenuStatusDot(status: status, isHot: isHot)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A status shown on the corner of a menu row's leading glyph.
///
/// A status is a dot and nothing else; a row with no status draws nothing and
/// holds no space.
enum WarrenDesktopMenuStatus: Equatable {
    case ok(Color)
    case failed(Color)
    case checking

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.ok(let a), .ok(let b)): a == b
        case (.failed(let a), .failed(let b)): a == b
        case (.checking, .checking): true
        default: false
        }
    }
}

/// The corner status dot a menu row draws on its leading glyph.
struct WarrenDesktopMenuStatusDot: View {
    let status: WarrenDesktopMenuStatus
    let isHot: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        let size = WarrenDesktopMenuMetrics.statusDotSize
        ZStack {
            Circle()
                .fill(isHot ? palette.hotRing : palette.surface)
                .frame(width: size + 3, height: size + 3)
            switch status {
            case .ok(let color), .failed(let color):
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
            case .checking:
                // Only a probe in flight moves; a settled result sits still.
                // The pulse is the Core Animation ring every activity dot
                // uses, so it never re-renders the hosting view each frame
                // and it stops as soon as Reduce Motion is turned on.
                WarrenStatusIndicator(
                    color: palette.secondaryGlyph,
                    isActive: true,
                    size: size,
                    intensity: .quiet,
                    accessibilityLabel: "Checking"
                )
            }
        }
        .frame(width: size + 3, height: size + 3)
        .offset(x: 3 + 1.5, y: 3 + 1.5)
        .accessibilityHidden(true)
    }
}

/// A Host's tile inside a menu: a neutral square ringed in grey with the
/// name's lowercase initial, with the probe's result on its corner.
struct WarrenDesktopMenuTile: View {
    let initial: String
    var isFailed = false
    var status: WarrenDesktopMenuStatus? = nil
    var isHot = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: WarrenDesktopMenuMetrics.tileRadius, style: .continuous)
        Text(initial)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(isFailed ? palette.tileFailedText : palette.rowText)
            .frame(width: WarrenDesktopMenuMetrics.tileSize, height: WarrenDesktopMenuMetrics.tileSize)
            .background(shape.fill(palette.tileFill))
            .overlay {
                shape.strokeBorder(isFailed ? palette.tileFailedBorder : palette.tileBorder, lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    WarrenDesktopMenuStatusDot(status: status, isHot: isHot)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The inline action a menu row reveals on hover: a copy button, a sidebar
/// membership toggle, and the like.
struct WarrenDesktopMenuInlineButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(isHovered ? palette.iconHover : (isActive ? palette.iconHover : palette.actionGlyph))
                .frame(width: WarrenDesktopMenuMetrics.actionSize, height: WarrenDesktopMenuMetrics.actionSize)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? palette.pressFill : .clear)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .warrenTooltip(label)
        .accessibilityLabel(label)
    }
}

/// The row a drilled-in page leads with: ‹ and the page's title at 13
/// semibold, 30 high, as the menu spec draws it. The whole row goes back,
/// not only the chevron, so the target is the row rather than a 22pt glyph.
struct WarrenDesktopMenuBackRow<Leading: View>: View {
    let title: String
    var backLabel = "Back"
    let onBack: () -> Void
    @ViewBuilder var leading: () -> Leading

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHovered ? palette.rowHoverText : palette.secondaryGlyph)
                    .frame(
                        width: WarrenDesktopMenuMetrics.actionSize,
                        height: WarrenDesktopMenuMetrics.actionSize
                    )
                leading()
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.rowText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .frame(height: WarrenDesktopMenuMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(backLabel)
        .accessibilityValue(title)
    }
}

extension WarrenDesktopMenuBackRow where Leading == EmptyView {
    init(title: String, backLabel: String = "Back", onBack: @escaping () -> Void) {
        self.init(title: title, backLabel: backLabel, onBack: onBack) { EmptyView() }
    }
}

/// A named group inside a menu. Titles name the list rather than decorate it,
/// so only lists that need a name carry one.
struct WarrenDesktopMenuGroupHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .tracking(WarrenDesktopMenuMetrics.headerTracking)
                .foregroundStyle(palette.headerText)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.leading, WarrenDesktopMenuMetrics.rowHorizontalPadding)
        .padding(.trailing, 2)
        .frame(height: WarrenDesktopMenuMetrics.headerHeight)
    }
}

extension WarrenDesktopMenuGroupHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}
