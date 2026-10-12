import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What the main window is made of.
///
/// `opaque` is Ember as it has always shipped: every region paints its own
/// opaque surface. `glass` makes the window itself the material — the desktop
/// shows through one translucent coat, regions stop painting, and hierarchy is
/// carried by how dense a surface is rather than by a stack of opaque plates.
public enum WarrenWindowMaterial: String, Sendable, Equatable {
    case opaque
    case glass

    /// Accessibility wins over the preference: with Reduce Transparency on,
    /// the window stays opaque whatever the user chose here.
    public static func resolve(
        glassEnabled: Bool,
        reduceTransparency: Bool
    ) -> Self {
        glassEnabled && !reduceTransparency ? .glass : .opaque
    }
}

/// The few numbers the glass material is built from.
///
/// Every glass surface derives from these; a component never writes its own
/// alpha. The densities follow one rule: the window carries a single coat, and
/// anything raised is the same Ember tone made denser, never a second coat.
public enum WarrenGlassMetrics {
    /// How much of `background` the window coat paints over the desktop.
    ///
    /// High on purpose. The sidebar text ladder was measured against an opaque
    /// ground, and a dense coat keeps the wallpaper's influence on it small.
    public static let coatDensity: Double = 0.90

    /// Raised surfaces — the composer, cards, inputs, popovers — as a fraction
    /// of `popoverSurface`: a floor plus a share of the coat density. Ember
    /// needs more of it than paper because lightening a dark ground reads
    /// weaker than darkening a light one at the same alpha.
    public static func raisedOpacity(isLight: Bool) -> Double {
        isLight ? 0.04 + 0.30 * coatDensity : 0.10 + 0.50 * coatDensity
    }

    /// The window already sits behind a coat, so a modal scrim needs less to
    /// make the app recede.
    public static func scrimOpacity(isLight: Bool) -> Double {
        isLight ? 0.18 : 0.30
    }

    /// Region boundaries on glass, as a fraction of `foreground`.
    public static let dividerOpacity: Double = 0.08
}

private struct WarrenWindowMaterialKey: EnvironmentKey {
    static let defaultValue = WarrenWindowMaterial.opaque
}

public extension EnvironmentValues {
    /// The material the enclosing window paints with. Opaque unless the
    /// window's root opts in.
    var warrenWindowMaterial: WarrenWindowMaterial {
        get { self[WarrenWindowMaterialKey.self] }
        set { self[WarrenWindowMaterialKey.self] = newValue }
    }
}

private struct WarrenGlassLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Whether the person turned the translucent window on, regardless of
    /// whether the window can show it.
    ///
    /// Layout that came with the glass design — the Conversation's composer
    /// stack, for one — reads this rather than the material, because it is
    /// about arrangement, not translucency. Reduce Transparency takes the
    /// glass away; it should not also rearrange the screen.
    var warrenGlassLayout: Bool {
        get { self[WarrenGlassLayoutKey.self] }
        set { self[WarrenGlassLayoutKey.self] = newValue }
    }
}

#if os(macOS)
/// The window's one coat: the system's behind-window blur with a single
/// translucent layer of `background` on top.
///
/// It is drawn once, under everything, and only on glass. Using `background`
/// rather than a chrome color is deliberate: it is the terminal's own ground,
/// so a transparent terminal sitting on the coat still matches what it reports
/// over OSC 11.
public struct WarrenWindowCoat: View {
    private let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        ZStack {
            WarrenBehindWindowBlur(cornerRadius: cornerRadius)
            tokens.background.opacity(WarrenGlassMetrics.coatDensity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// WindowServer-composited blur of whatever is behind the window. It costs the
/// app nothing per frame, so it does not compete with terminal rendering.
private struct WarrenBehindWindowBlur: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> WarrenBehindWindowBlurView {
        let view = WarrenBehindWindowBlurView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: WarrenBehindWindowBlurView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}

/// Keeps the blur inside the window's rounded corners.
///
/// The content layer's corner mask does not reach a behind-window effect,
/// which WindowServer draws from the view's frame; without its own mask the
/// blur would show square corners outside the window shape. Full screen has
/// no corners, so the mask is dropped there.
private final class WarrenBehindWindowBlurView: NSVisualEffectView {
    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            updateMask()
        }
    }

    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let window {
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateMask()
                    }
                })
            }
        }
        updateMask()
    }

    private func updateMask() {
        let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        maskImage = isFullScreen || cornerRadius <= 0
            ? nil
            : Self.roundedMask(radius: cornerRadius)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
#endif
