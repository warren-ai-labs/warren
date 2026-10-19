import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Placeholder rows shaped like the list that is loading.
///
/// A centred spinner says only "wait"; rows in the list's own shape say what
/// is coming and keep the page from jumping when it arrives. Each row is a
/// leading dot, a title line, an optional meta line and an optional trailing
/// figure, which covers commits, changed files and file trees.
public struct WarrenSkeletonRows: View {
    public struct RowShape: Sendable {
        public var showsDot: Bool
        public var showsMeta: Bool
        public var showsTrailing: Bool
        public var rowHeight: CGFloat
        public var horizontalPadding: CGFloat

        public init(
            showsDot: Bool = true,
            showsMeta: Bool = true,
            showsTrailing: Bool = false,
            rowHeight: CGFloat = 46,
            horizontalPadding: CGFloat = 12
        ) {
            self.showsDot = showsDot
            self.showsMeta = showsMeta
            self.showsTrailing = showsTrailing
            self.rowHeight = rowHeight
            self.horizontalPadding = horizontalPadding
        }

        /// A commit: dot, subject, hash · author · time, line counts.
        public static let commit = RowShape(showsTrailing: true)
        /// A changed file: status dot, path, counts.
        public static let change = RowShape(showsMeta: false, showsTrailing: true, rowHeight: 28)
        /// A file tree row: glyph and name.
        public static let file = RowShape(showsMeta: false, rowHeight: 24)
    }

    private let count: Int
    private let shape: RowShape

    /// Title widths, as fractions of the row, so the rows read as text of
    /// different lengths rather than as a grid.
    private static let titleWidths: [CGFloat] = [0.86, 0.72, 0.78, 0.64, 0.90, 0.70, 0.58, 0.82]

    public init(count: Int = 6, shape: RowShape = .commit) {
        self.count = count
        self.shape = shape
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                row(index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    private func row(_ index: Int) -> some View {
        // Rows breathe a beat apart from top to bottom, so the block reads as
        // one slow wave instead of every bar pulsing in step.
        let phase = Double(index) * 0.09
        return HStack(alignment: shape.showsMeta ? .top : .center, spacing: 8) {
            if shape.showsDot {
                WarrenSkeletonBar(phase: phase)
                    .frame(width: 6, height: 6)
                    .clipShape(Circle())
                    .padding(.top, shape.showsMeta ? 6 : 0)
            }
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 7) {
                    WarrenSkeletonBar(phase: phase)
                        .frame(width: proxy.size.width * Self.titleWidths[index % Self.titleWidths.count], height: 9)
                    if shape.showsMeta {
                        WarrenSkeletonBar(phase: phase)
                            .frame(width: proxy.size.width * 0.44, height: 7)
                    }
                }
                .frame(maxHeight: .infinity, alignment: shape.showsMeta ? .top : .center)
                .padding(.top, shape.showsMeta ? 4 : 0)
            }
            if shape.showsTrailing {
                WarrenSkeletonBar(phase: phase)
                    .frame(width: 44, height: 7)
                    .padding(.top, shape.showsMeta ? 5 : 0)
            }
        }
        .padding(.horizontal, shape.horizontalPadding)
        .padding(.vertical, shape.showsMeta ? 9 : 0)
        .frame(height: shape.rowHeight)
    }
}

/// One placeholder bar.
///
/// The breathing runs on Core Animation, below SwiftUI's invalidation
/// boundary, for the reason `WarrenStatusPulseView` gives: a SwiftUI
/// `repeatForever` would make the whole hosting view redraw every frame next
/// to a live terminal. Under Reduce Motion the bar holds still.
public struct WarrenSkeletonBar: View {
    private let phase: Double

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.warrenSkeletonTint) private var tint

    public init(phase: Double = 0) {
        self.phase = phase
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenSkeletonPulse(color: tint ?? tokens.muted, phase: phase, animates: !reduceMotion)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct WarrenSkeletonTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

public extension EnvironmentValues {
    /// The bar colour for skeletons below this point; nil keeps `muted`.
    var warrenSkeletonTint: Color? {
        get { self[WarrenSkeletonTintKey.self] }
        set { self[WarrenSkeletonTintKey.self] = newValue }
    }
}

public extension View {
    /// Draws skeleton bars in `color`. For a client whose own palette puts
    /// rows on a ground `muted` does not separate from, such as iOS's dark
    /// grouped rows.
    func warrenSkeletonTint(_ color: Color?) -> some View {
        environment(\.warrenSkeletonTint, color)
    }
}

#if os(macOS)
private struct WarrenSkeletonPulse: NSViewRepresentable {
    let color: Color
    let phase: Double
    let animates: Bool

    func makeNSView(context: Context) -> WarrenSkeletonPulseView {
        let view = WarrenSkeletonPulseView()
        view.update(color: NSColor(color).cgColor, phase: phase, animates: animates)
        return view
    }

    func updateNSView(_ nsView: WarrenSkeletonPulseView, context: Context) {
        nsView.update(color: NSColor(color).cgColor, phase: phase, animates: animates)
    }
}

@MainActor
final class WarrenSkeletonPulseView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(color: CGColor, phase: Double, animates: Bool) {
        guard let layer else { return }
        layer.backgroundColor = color
        WarrenSkeletonPulseAnimation.apply(to: layer, phase: phase, animates: animates)
    }
}
#else
private struct WarrenSkeletonPulse: UIViewRepresentable {
    let color: Color
    let phase: Double
    let animates: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.layer.backgroundColor = Self.cgColor(color, in: context)
        WarrenSkeletonPulseAnimation.apply(to: view.layer, phase: phase, animates: animates)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.layer.backgroundColor = Self.cgColor(color, in: context)
        WarrenSkeletonPulseAnimation.apply(to: uiView.layer, phase: phase, animates: animates)
    }

    /// A layer colour does not follow trait changes by itself, and a dynamic
    /// tint would otherwise resolve against whatever trait collection happens
    /// to be current. Resolve it against the scheme SwiftUI is drawing in,
    /// which honours an app-level appearance override.
    private static func cgColor(_ color: Color, in context: Context) -> CGColor {
        let style: UIUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        return UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).cgColor
    }
}
#endif

private enum WarrenSkeletonPulseAnimation {
    static let key = "warren.skeleton-pulse"
    static let duration: CFTimeInterval = 0.9

    @MainActor
    static func apply(to layer: CALayer, phase: Double, animates: Bool) {
        guard animates else {
            layer.removeAnimation(forKey: key)
            return
        }
        guard layer.animation(forKey: key) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.5
        pulse.duration = duration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.timeOffset = phase
        pulse.isRemovedOnCompletion = false
        layer.add(pulse, forKey: key)
    }
}
