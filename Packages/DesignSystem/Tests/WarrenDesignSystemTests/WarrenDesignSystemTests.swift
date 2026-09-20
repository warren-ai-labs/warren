import SwiftUI
import XCTest
@testable import WarrenDesignSystem

final class WarrenDesignSystemTests: XCTestCase {
    func testSidebarWidthPolicySnapsAndClamps() {
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 119), 52)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 220), 220)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 320), 320)
        XCTAssertEqual(WarrenLayoutMetrics.sidebarWidth(for: 401), 400)
    }

    /// A row must never read louder than the row that contains it. A leaf that
    /// outranked its own workspace inverted the tree: the deepest rows were the
    /// loudest and the eye could not find where one workspace ended.
    func testSidebarTextWeightsDescendWithTreeDepth() {
        let tiers = WarrenSidebarTextWeight.descendingTiers
        XCTAssertEqual(tiers.count, 3)
        XCTAssertEqual(tiers, tiers.sorted(by: >))
        XCTAssertEqual(Set(tiers).count, tiers.count, "Two tiers at one weight is no tier")

        // Metadata rides along with the row it annotates rather than forming its
        // own depth, so it sits at the quietest tier instead of below it.
        XCTAssertEqual(WarrenSidebarTextWeight.meta, tiers.last)
        XCTAssertTrue(tiers.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    func testInteractionStatePriority() {
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: true, pressed: true, selected: true, focused: true, hovered: true),
            .disabled
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: true, selected: true, focused: true, hovered: true),
            .pressed
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: false, selected: true, focused: true, hovered: true),
            .selected
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: false, selected: false, focused: true, hovered: true),
            .focused
        )
        XCTAssertEqual(
            WarrenInteractionState.resolve(disabled: false, pressed: false, selected: false, focused: false, hovered: true),
            .hovered
        )
    }

    func testMotionPolicyDisablesAnimationsForReducedMotion() {
        XCTAssertNil(WarrenMotion.animation(.feedback, reduceMotion: true))
        XCTAssertNil(WarrenMotion.animation(.stateChange, reduceMotion: true))
        XCTAssertNil(WarrenMotion.animation(.overlay, reduceMotion: true))
        XCTAssertNotNil(WarrenMotion.animation(.feedback, reduceMotion: false))
        XCTAssertLessThan(WarrenMotion.feedbackDuration, WarrenMotion.overlayDuration)
    }

    func testBrailleSpinnerFrameDurationFormsAnEightStepCycle() {
        XCTAssertEqual(WarrenMotion.spinnerFrameDuration, 0.09)
        XCTAssertEqual(WarrenMotion.spinnerFrameDuration * 8, 0.72, accuracy: 0.0001)
    }

    #if os(macOS)
    @MainActor
    func testStatusPulseUsesOnePersistentCoreAnimation() {
        let view = WarrenStatusPulseView(color: .systemOrange, size: 7)
        let animation = view.layer?.sublayers?.first?.animation(
            forKey: WarrenStatusPulseView.animationKey
        ) as? CAAnimationGroup

        XCTAssertEqual(animation?.duration, WarrenMotion.activityPulseDuration)
        XCTAssertEqual(animation?.repeatCount, .infinity)
        XCTAssertEqual(animation?.animations?.count, 2)

        view.update(color: .systemRed, size: 9)
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 9, height: 9))
        XCTAssertNotNil(view.layer?.sublayers?.first?.animation(
            forKey: WarrenStatusPulseView.animationKey
        ))
        XCTAssertEqual(view.layer?.sublayers?.count, 1)
    }
    #endif

    func testPresentationStackTracksTopmostRole() {
        var stack = WarrenPresentationStack()
        XCTAssertTrue(stack.isEmpty)
        XCTAssertNil(stack.top)
        stack.push(.popover)
        stack.push(.modal)
        XCTAssertEqual(stack.top, .modal)
        XCTAssertEqual(stack.popTop(), .modal)
        XCTAssertEqual(stack.top, .popover)
        XCTAssertEqual(stack.popTop(), .popover)
        XCTAssertTrue(stack.isEmpty)
    }

    func testModalNeverDismissesOnBackdrop() {
        let stack = WarrenPresentationStack()
        XCTAssertFalse(stack.allowsBackdropDismiss(role: .modal, hasEdits: false))
        XCTAssertFalse(stack.allowsBackdropDismiss(role: .modal, hasEdits: true))
    }

    func testSheetBackdropDismissRequiresNoUncommittedEdits() {
        let stack = WarrenPresentationStack()
        XCTAssertFalse(stack.allowsBackdropDismiss(role: .sheet, hasEdits: true))
        XCTAssertTrue(stack.allowsBackdropDismiss(role: .sheet, hasEdits: false))
    }

    func testCommandPopoverAndMenuDismissOnBackdrop() {
        let stack = WarrenPresentationStack()
        for role in [WarrenPresentationRole.commandSurface, .popover, .menu] {
            XCTAssertTrue(stack.allowsBackdropDismiss(role: role, hasEdits: true), "\(role)")
        }
    }

    func testEscapeDismissalIsAllowedForInteractiveSurfacesOnly() {
        let stack = WarrenPresentationStack()
        for role in [WarrenPresentationRole.modal, .sheet, .commandSurface, .popover, .menu] {
            XCTAssertTrue(stack.allowsEscapeDismiss(role: role), "\(role)")
        }
        XCTAssertFalse(stack.allowsEscapeDismiss(role: .status))
        XCTAssertFalse(stack.allowsEscapeDismiss(role: .inline))
    }

    func testResolvedTokensAnswerTheRequestedAppearance() {
        XCTAssertEqual(
            WarrenColorTokens.resolved(for: .dark).background,
            WarrenColorTokens.dark.background
        )
        XCTAssertEqual(
            WarrenColorTokens.resolved(for: .light).background,
            WarrenColorTokens.light.background
        )
        XCTAssertNotEqual(
            WarrenColorTokens.light.background,
            WarrenColorTokens.dark.background,
            "Two appearances resolving to one ground is a dark-only build"
        )
    }

    #if os(macOS)
    /// Text has to sit on the opposite side of its ground in each appearance.
    ///
    /// This is the one property a light palette can silently get wrong: copying
    /// a foreground over from the dark set leaves light-on-light, which reads as
    /// a blank panel rather than as a styling mistake.
    func testEachAppearanceKeepsForegroundOppositeItsBackground() {
        XCTAssertLessThan(
            Self.luminance(WarrenColorTokens.dark.background),
            Self.luminance(WarrenColorTokens.dark.foreground)
        )
        XCTAssertGreaterThan(
            Self.luminance(WarrenColorTokens.light.background),
            Self.luminance(WarrenColorTokens.light.foreground)
        )
    }

    /// Body text and the accent must clear WCAG AA for small text against their
    /// own ground. The accent is included because it is used as label text, not
    /// only as a fill.
    func testBothAppearancesMeetContrastMinimums() {
        for (name, tokens) in [
            ("light", WarrenColorTokens.light),
            ("dark", WarrenColorTokens.dark),
        ] {
            let ground = tokens.background
            XCTAssertGreaterThan(
                Self.contrastRatio(tokens.foreground, ground), 7,
                "\(name) body text should clear AAA"
            )
            XCTAssertGreaterThan(
                Self.contrastRatio(tokens.mutedForeground, ground), 4.5,
                "\(name) secondary text should clear AA"
            )
            XCTAssertGreaterThan(
                Self.contrastRatio(tokens.highlight, ground), 3,
                "\(name) accent is used as label text, not only as a fill"
            )
            for status in [tokens.success, tokens.warning, tokens.destructive, tokens.info, tokens.link] {
                XCTAssertGreaterThan(
                    Self.contrastRatio(status, ground), 3,
                    "\(name) status colors double as small text"
                )
            }
        }
    }

    /// A wash lifts a row off the ground in dark and presses it into the ground
    /// in light. Either way the selected row must read as further from the
    /// ground than the hovered one, or selection and hover swap meanings.
    func testWashesSeparateHoverFromSelectionInBothAppearances() {
        for (name, tokens) in [
            ("light", WarrenColorTokens.light),
            ("dark", WarrenColorTokens.dark),
        ] {
            let ground = Self.luminance(tokens.background)
            let hover = abs(Self.luminance(Self.flatten(tokens.fillHover, over: tokens.background)) - ground)
            let selected = abs(Self.luminance(Self.flatten(tokens.fillSelected, over: tokens.background)) - ground)
            let tertiary = abs(Self.luminance(Self.flatten(tokens.tertiaryWash, over: tokens.background)) - ground)
            XCTAssertGreaterThan(selected, hover, "\(name) selection must outrank hover")
            XCTAssertGreaterThan(hover, tertiary, "\(name) hover must outrank the tertiary wash")
            XCTAssertGreaterThan(tertiary, 0, "\(name) tertiary wash has to be visible at all")
        }
    }

    /// Host sections and split groups index these by position, so the two
    /// appearances have to offer the same number of identities — otherwise the
    /// same resource picks a different hue depending on the appearance.
    func testIdentityTintsAreParallelAndDistinctInBothAppearances() {
        let light = WarrenColorTokens.light.hostSectionTints
        let dark = WarrenColorTokens.dark.hostSectionTints
        XCTAssertEqual(light.count, dark.count)
        XCTAssertEqual(light.count, 8)
        XCTAssertEqual(Set(light.map(Self.rgbKey)).count, light.count)
        XCTAssertEqual(Set(dark.map(Self.rgbKey)).count, dark.count)
        XCTAssertEqual(WarrenColorTokens.light.tabGroupTints.map(Self.rgbKey), light.map(Self.rgbKey))

        // Drawn at full strength as a rule on their own ground, so each has to
        // stay distinguishable from it.
        for (index, tint) in light.enumerated() {
            XCTAssertGreaterThan(
                Self.contrastRatio(tint, WarrenColorTokens.light.background), 2.5,
                "Light identity tint \(index) disappears on paper"
            )
        }
    }

    /// The scrim darkens whatever is behind it, so it cannot be derived from a
    /// foreground that flips with the appearance.
    func testModalScrimDarkensInBothAppearances() {
        for tokens in [WarrenColorTokens.light, WarrenColorTokens.dark] {
            let flattened = Self.flatten(tokens.modalScrim, over: tokens.background)
            XCTAssertLessThan(Self.luminance(flattened), Self.luminance(tokens.background))
        }
    }

    /// An inactive pane has to read as receding in both appearances. A
    /// `foreground`-derived wash would lighten paper, making the pane that does
    /// not hold the keyboard the brighter one.
    func testInactivePaneWashRecedesInBothAppearances() {
        for tokens in [WarrenColorTokens.light, WarrenColorTokens.dark] {
            let washed = Self.flatten(tokens.terminalInactiveWash, over: tokens.background)
            XCTAssertLessThan(Self.luminance(washed), Self.luminance(tokens.background))
        }
    }

    /// A sidebar row that names something a user navigates by has to clear the
    /// small-text floor. The two quietest tiers are deliberately below it — they
    /// are de-emphasized metadata, and Ember has shipped them that way — so they
    /// are held to the 3:1 UI floor and to parity below.
    func testSidebarRowTextClearsTheSmallTextFloorInBothAppearances() {
        for (name, tokens) in [
            ("light", WarrenColorTokens.light),
            ("dark", WarrenColorTokens.dark),
        ] {
            let surface = tokens.sidebarSurface
            let rowTiers: [(String, Color)] = [
                ("project", tokens.projectText),
                ("workspaceSelected", tokens.workspaceSelectedText),
                ("workspace", tokens.workspaceText),
                ("leaf", tokens.sidebarLeafText),
                ("metaActive", tokens.sidebarMetaTextActive),
            ]
            for (tier, color) in rowTiers {
                XCTAssertGreaterThan(
                    Self.contrastRatio(Self.flatten(color, over: surface), surface), 4.5,
                    "\(name) sidebar \(tier) text is below the small-text floor"
                )
            }
            for (tier, color) in [
                ("section", tokens.sidebarSectionText),
                ("meta", tokens.sidebarMetaText),
            ] {
                XCTAssertGreaterThan(
                    Self.contrastRatio(Self.flatten(color, over: surface), surface), 3,
                    "\(name) sidebar \(tier) text has receded out of legibility"
                )
            }
        }
    }

    /// The light appearance must be no less legible than Ember at the same tier.
    ///
    /// This is the assertion that would have caught the original bug. The tiers
    /// are a fade, and a fade loses contrast far faster against paper than
    /// against Ember: the fractions were measured on a dark ground, and reusing
    /// them from `mutedForeground` put light metadata at 2.3:1 where Ember gives
    /// 3.3:1. Parity states the intent directly — a light appearance is an
    /// appearance, not a degraded one — without freezing either palette's
    /// absolute values.
    func testLightSidebarTextIsNeverQuieterThanEmber() {
        let light = WarrenColorTokens.light
        let dark = WarrenColorTokens.dark
        let tiers: [(String, KeyPath<WarrenColorTokens, Color>)] = [
            ("project", \.projectText),
            ("workspaceSelected", \.workspaceSelectedText),
            ("workspace", \.workspaceText),
            ("leaf", \.sidebarLeafText),
            ("section", \.sidebarSectionText),
            ("meta", \.sidebarMetaText),
            ("metaActive", \.sidebarMetaTextActive),
        ]

        for (tier, tierColor) in tiers {
            let lightRatio = Self.contrastRatio(
                Self.flatten(light[keyPath: tierColor], over: light.sidebarSurface),
                light.sidebarSurface
            )
            let darkRatio = Self.contrastRatio(
                Self.flatten(dark[keyPath: tierColor], over: dark.sidebarSurface),
                dark.sidebarSurface
            )
            XCTAssertGreaterThan(
                lightRatio, darkRatio * 0.9,
                "light sidebar \(tier) reads meaningfully quieter than Ember's"
            )
        }
    }

    /// The ladder still has to descend after being floored, or every row reads
    /// at one volume and the tree loses its shape.
    func testSidebarTextTiersStayOrderedInBothAppearances() {
        for (name, tokens) in [
            ("light", WarrenColorTokens.light),
            ("dark", WarrenColorTokens.dark),
        ] {
            let surface = tokens.sidebarSurface
            // Distance from the surface, which is what "louder" means in either
            // appearance: on Ember the tiers climb away from a dark ground, on
            // paper they descend away from a light one.
            func distance(_ color: Color) -> Double {
                abs(
                    Self.luminance(Self.flatten(color, over: surface))
                        - Self.luminance(surface)
                )
            }
            XCTAssertGreaterThan(
                distance(tokens.workspaceText), distance(tokens.sidebarLeafText),
                "\(name): a workspace must read louder than its own leaves"
            )
            XCTAssertGreaterThan(
                distance(tokens.sidebarLeafText), distance(tokens.sidebarSectionText),
                "\(name): a leaf must read louder than a section heading"
            )
        }
    }

    private static func components(_ color: Color) -> (Double, Double, Double, Double) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            return (0, 0, 0, 1)
        }
        return (
            Double(srgb.redComponent),
            Double(srgb.greenComponent),
            Double(srgb.blueComponent),
            Double(srgb.alphaComponent)
        )
    }

    private static func rgbKey(_ color: Color) -> String {
        let (red, green, blue, _) = components(color)
        return String(format: "%.4f-%.4f-%.4f", red, green, blue)
    }

    /// Composites a translucent wash over an opaque ground, which is what the
    /// eye actually sees. Comparing the wash's own alpha would say nothing about
    /// whether it reads on that ground.
    private static func flatten(_ wash: Color, over ground: Color) -> Color {
        let (washRed, washGreen, washBlue, alpha) = components(wash)
        let (groundRed, groundGreen, groundBlue, _) = components(ground)
        return Color(
            red: washRed * alpha + groundRed * (1 - alpha),
            green: washGreen * alpha + groundGreen * (1 - alpha),
            blue: washBlue * alpha + groundBlue * (1 - alpha)
        )
    }

    /// WCAG relative luminance.
    private static func luminance(_ color: Color) -> Double {
        let (red, green, blue, _) = components(color)
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func contrastRatio(_ first: Color, _ second: Color) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }
    #endif
}
