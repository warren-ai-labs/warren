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

    let tileFill: Color
    let tileBorder: Color

    let addText: Color

    static func resolved(for colorScheme: ColorScheme) -> Self {
        colorScheme == .light ? .light : .dark
    }

    static let dark = make(for: .dark)
    static let light = make(for: .light)

    /// A menu is a raised surface, so it takes the same tone as every other
    /// raised surface instead of a grey of its own.
    ///
    /// These twenty-six values used to be literals — a #141414 card, a #262626
    /// hairline, its own quiet greys — which put a menu a step darker than the
    /// popover it sat beside and let it drift every time the palette moved. The
    /// menu now reads the resolved tokens, so it cannot.
    private static func make(for colorScheme: ColorScheme) -> Self {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        // A corner dot on a hot row has to cut itself out of what is under it,
        // and the hover wash is translucent: the ring is the wash already
        // composited over the card, which is the solid step the palette
        // mechanism exists for.
        let hoverAlpha = WarrenRGB(tokens.fillHover).alpha
        let hotRing = WarrenRGB(tokens.popoverSurface)
            .mixed(with: WarrenRGB(tokens.foreground), hoverAlpha)
            .color
        return Self(
            surface: tokens.popoverSurface,
            border: tokens.border,
            // Paper has no light to catch along a card's top edge.
            topHighlight: colorScheme == .light ? .clear : Color.white.opacity(0.05),
            divider: tokens.border,
            headerText: tokens.ink4,
            rowText: tokens.foreground,
            rowHoverText: tokens.foreground,
            meta: tokens.ink3,
            secondaryGlyph: tokens.ink3,
            value: tokens.ink4,
            chevron: tokens.ink4,
            icon: tokens.ink3,
            iconHover: tokens.foreground,
            check: tokens.foreground,
            hoverFill: tokens.fillHover,
            pressFill: tokens.fillSelected,
            hotRing: hotRing,
            actionGlyph: tokens.ink3,
            dangerText: tokens.destructive,
            dangerIcon: tokens.destructive,
            tileFill: tokens.muted,
            tileBorder: tokens.ring,
            addText: tokens.ink3
        )
    }
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

/// A keyboard shortcut, as one run of quiet text.
///
/// It used to be one 18×18 cap per key. Two boxes for `⌘T` were the densest
/// decoration left in a menu, and they were also why a row's right column never
/// shared an edge: every cap had its own border and its own width. The glyphs
/// already read as keys, so a menu says them in the secondary tier and stops
/// there.
struct WarrenDesktopMenuKeycaps: View {
    /// The keys as written, so `⌘T` stays one word and a chord that was given
    /// as separate caps keeps its space.
    let text: String

    init(keys: String) {
        text = keys
    }

    /// One entry per key, joined by a space.
    init(caps: [String]) {
        text = caps.joined(separator: " ")
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
            .foregroundStyle(WarrenDesktopMenuPalette.resolved(for: colorScheme).meta)
            .lineLimit(1)
            .accessibilityHidden(true)
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
                    RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
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
            // A menu's group label is a quiet sentence-case caption, the way
            // Superset's menus draw one. Tracked capitals were the loudest text
            // in a surface whose whole job is to stay out of the way, and a menu
            // with two or three groups read as a wall of labels.
            Text(title)
                .font(.system(size: 12, weight: .regular))
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
