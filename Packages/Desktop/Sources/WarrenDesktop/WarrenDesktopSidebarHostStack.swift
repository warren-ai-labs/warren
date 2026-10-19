import SwiftUI
import WarrenDesignSystem
import WarrenObservation

/// A Host the sidebar's foot offers to switch to.
struct WarrenDesktopSidebarOtherHost: Identifiable, Equatable {
    /// The endpoint ID.
    let id: String
    let name: String
    let isLocal: Bool
    /// Where the Host is reached: an address, an SSH target or a machine
    /// name. `nil` when the endpoint names none.
    let address: String?
    let isOnline: Bool
    /// The states of its Sessions that have one, most urgent first. Only a
    /// Host whose sections this window loads can report them.
    let marks: [WarrenActivityMark]

    init(
        id: String,
        name: String,
        isLocal: Bool = false,
        address: String? = nil,
        isOnline: Bool = true,
        marks: [WarrenActivityMark] = []
    ) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
        self.address = address
        self.isOnline = isOnline
        self.marks = marks
    }

    /// The address an endpoint's detail names, without the route it is
    /// reached by: "SSH · dev@fsn1" names `dev@fsn1`.
    static func address(fromDetail detail: String?) -> String? {
        guard var value = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.hasPrefix("SSH · ") {
            value = String(value.dropFirst("SSH · ".count))
        }
        return value.isEmpty ? nil : value
    }

    /// Whether one of its Sessions is waiting for a person.
    var needsAttention: Bool {
        marks.contains { $0.tier == .actionable }
    }

    /// The tile's letter: the name's initial, lowercase, the way hostnames
    /// are typed.
    var initial: String {
        String(name.prefix(1)).lowercased()
    }

    /// The panel row's second line: where the Host is and what it is, or
    /// that it is offline.
    var panelSubtitle: String {
        let place = isOnline ? (isLocal ? "Local" : "Server") : "Offline"
        guard let address, !address.isEmpty else { return place }
        return "\(place) · \(address)"
    }

    /// What the foot's label says beside the name while this Host is under
    /// the pointer.
    var pickDetail: String? {
        isOnline ? address : "offline"
    }
}

/// The foot's measurements and motion, from the adopted sidebar spec.
enum WarrenDesktopSidebarHostStackMetrics {
    static let height: CGFloat = 44
    static let leadingInset: CGFloat = 16
    static let trailingInset: CGFloat = 10
    static let spacing: CGFloat = 10
    static let tileSize: CGFloat = 20
    static let tileRadius: CGFloat = 6
    /// The stack's own width at rest: three tiles overlapping.
    static let stackWidth: CGFloat = 34
    static let maximumStackedTiles = 3
    static let restPitch: CGFloat = 7
    static let liftedPitch: CGFloat = 24
    static let liftedRise: CGFloat = 3
    static let hotRise: CGFloat = 6
    static let hotScale: CGFloat = 1.15
    static let labelShift: CGFloat = 60
    static let tileDotSize: CGFloat = 7
    static let attentionDotSize: CGFloat = 6
    /// Between the panel's bottom edge and the foot.
    static let panelGap: CGFloat = 6
    static let panelInset: CGFloat = 8
    static let panelRadius: CGFloat = 12
    /// How long the pointer rests on the foot before the tiles lift, and
    /// before the panel rises.
    static let liftDelay: Duration = .seconds(WarrenDesktopHoverIntent.liftDelay)
    static let pullDelay: Duration = .seconds(WarrenDesktopHoverIntent.pullDelay)
    static let dropDelay: Duration = .seconds(WarrenDesktopHoverIntent.dropDelay)
    /// Moving the pointer into this band at the foot's top edge raises the
    /// panel at once.
    static let pullBand: CGFloat = 6


    /// Where tile `index` sits relative to the stack's leading edge.
    static func tileOffset(index: Int, isLifted: Bool, hotIndex: Int?) -> CGSize {
        guard isLifted else {
            return CGSize(width: CGFloat(index) * restPitch, height: 0)
        }
        let rise = index == hotIndex ? hotRise : liftedRise
        return CGSize(width: CGFloat(index) * liftedPitch, height: -rise)
    }

    static func tileScale(index: Int, isLifted: Bool, hotIndex: Int?) -> CGFloat {
        isLifted && index == hotIndex ? hotScale : 1
    }

    /// The lifted tile under a pointer at `x` from the stack's leading edge,
    /// if any.
    static func tileIndex(atX x: CGFloat, tileCount: Int) -> Int? {
        guard x >= 0 else { return nil }
        let index = Int(x / liftedPitch)
        guard index < tileCount, x - CGFloat(index) * liftedPitch <= tileSize else { return nil }
        return index
    }
}

/// The sidebar's foot when other Hosts exist: their tiles stacked, "Other
/// hosts" and the count, and a dot while a Session on one of them needs
/// someone.
///
/// The same gesture as the top bar's split group. Hovering lifts and fans the
/// tiles, and the label names the Host under the pointer; clicking switches
/// to it. Resting a moment, or moving the pointer up, raises a panel with one
/// row per Host.
struct WarrenDesktopSidebarHostStack: View {
    let hosts: [WarrenDesktopSidebarOtherHost]
    let onSelectHost: (String) -> Void
    let onAddHost: (() -> Void)?
    /// A control that shares the foot's row at its trailing end, outside the
    /// hover that lifts the tiles: the notice bell.
    let trailingAccessory: AnyView?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isLifted = false
    @State private var isPulled = false
    @State private var hotIndex: Int?
    @State private var isPointerInFoot = false
    @State private var isPointerInPanel = false
    @State private var isAddHovered = false
    @State private var timer: Task<Void, Never>?
    /// The foot's distance from the window's top, the most the panel may rise.
    @State private var roomAbove: CGFloat?

    private typealias Metrics = WarrenDesktopSidebarHostStackMetrics

    init(
        hosts: [WarrenDesktopSidebarOtherHost],
        onSelectHost: @escaping (String) -> Void,
        onAddHost: (() -> Void)? = nil,
        trailingAccessory: AnyView? = nil,
        initiallyLifted: Bool = false,
        initiallyPulled: Bool = false,
        initialHotIndex: Int? = nil
    ) {
        self.hosts = hosts
        self.onSelectHost = onSelectHost
        self.onAddHost = onAddHost
        self.trailingAccessory = trailingAccessory
        _isLifted = State(initialValue: initiallyLifted || initiallyPulled)
        _isPulled = State(initialValue: initiallyPulled)
        _hotIndex = State(initialValue: initialHotIndex)
    }

    private var stackedHosts: ArraySlice<WarrenDesktopSidebarOtherHost> {
        hosts.prefix(Metrics.maximumStackedTiles)
    }

    private var needsAttention: Bool {
        hosts.contains(where: \.needsAttention)
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: 0) {
            foot(tokens: tokens)
            if let trailingAccessory {
                trailingAccessory
                    .padding(.trailing, 8)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(tokens.cardBorder)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .background {
            // How far the foot sits below the window's top: the panel
            // rises into that room and scrolls once the Hosts outgrow it.
            GeometryReader { proxy in
                let top = proxy.frame(in: .global).minY
                Color.clear
                    .onAppear { roomAbove = top }
                    .onChange(of: top) { roomAbove = $0 }
            }
        }
        .overlay(alignment: .top) {
            panel(tokens: tokens)
                .environment(\.warrenMenuMaxHeight, roomAbove.map {
                    $0 - Metrics.panelGap - WarrenLayoutMetrics.windowInset - 8
                })
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.panelInset)
                .frame(height: 0, alignment: .bottom)
                .offset(y: -Metrics.panelGap)
                .opacity(isPulled ? 1 : 0)
                .offset(y: isPulled ? 0 : 6)
                .allowsHitTesting(isPulled)
                .accessibilityHidden(!isPulled)
        }
        .onDisappear { timer?.cancel() }
    }

    // MARK: Foot

    private func foot(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: Metrics.spacing) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(stackedHosts.enumerated().reversed()), id: \.element.id) { index, host in
                    WarrenDesktopHostTile(
                        host: host,
                        showsStatus: isLifted,
                        outline: isLifted ? nil : tokens.workbenchCardFill,
                        isRaised: isLifted
                    )
                    .scaleEffect(Metrics.tileScale(index: index, isLifted: isLifted, hotIndex: hotIndex))
                    .offset(Metrics.tileOffset(index: index, isLifted: isLifted, hotIndex: hotIndex))
                }
            }
            .frame(width: Metrics.stackWidth, height: Metrics.tileSize, alignment: .topLeading)

            ZStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text("Other hosts")
                        .font(.system(size: 13))
                        .foregroundStyle(tokens.treeSecondaryText)
                    Text("\(hosts.count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.treeQuietText)
                }
                .opacity(isLifted ? 0 : 1)
                .offset(x: isLifted ? Metrics.labelShift : 0)

                if let host = hotHost {
                    HStack(spacing: 6) {
                        Text(host.name)
                            .font(.system(size: 13))
                            .foregroundStyle(tokens.treeGroupText)
                        if let detail = host.pickDetail {
                            Text(detail)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(tokens.treeQuietText)
                        }
                    }
                    .opacity(isLifted ? 1 : 0)
                    .offset(x: isLifted ? Metrics.labelShift : 0)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.tileSize)
            .clipped()

            if needsAttention {
                Circle()
                    .fill(tokens.highlight)
                    .frame(width: Metrics.attentionDotSize, height: Metrics.attentionDotSize)
                    .opacity(isLifted ? 0 : 1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, Metrics.leadingInset)
        .padding(.trailing, Metrics.trailingInset)
        .frame(height: Metrics.height)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            // The grip says the panel can be pulled up.
            Capsule()
                .fill(tokens.treeQuietText)
                .frame(width: 16, height: 2)
                .padding(.top, 3)
                .opacity(isLifted && !isPulled ? 0.8 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                footHovered(at: location)
            case .ended:
                isPointerInFoot = false
                scheduleDrop()
            }
        }
        .onTapGesture { selectHost(at: hotIndex ?? 0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Other hosts")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectHost(at: hotIndex ?? 0) }
        .warrenSemanticElement(
            id: "sidebar.other-hosts",
            role: .button,
            label: "Other hosts",
            value: accessibilityValue,
            action: { pull() }
        )
    }

    private var hotHost: WarrenDesktopSidebarOtherHost? {
        guard !hosts.isEmpty else { return nil }
        return hosts[min(max(hotIndex ?? 0, 0), hosts.count - 1)]
    }

    private var accessibilityValue: String {
        let count = hosts.count == 1 ? "1 host" : "\(hosts.count) hosts"
        return needsAttention ? "\(count). A session needs you" : count
    }

    private func footHovered(at location: CGPoint) {
        let entering = !isPointerInFoot
        isPointerInFoot = true
        if entering, !isLifted {
            schedule {
                try await Task.sleep(for: Metrics.liftDelay)
                lift()
                try await Task.sleep(for: Metrics.pullDelay - Metrics.liftDelay)
                pull()
            }
        } else if entering {
            timer?.cancel()
        }
        guard isLifted else { return }
        if location.y < Metrics.pullBand, !isPulled {
            pull()
        }
        let x = location.x - Metrics.leadingInset
        if let index = Metrics.tileIndex(atX: x, tileCount: stackedHosts.count), index != hotIndex {
            setHot(index)
        }
    }

    // MARK: Panel

    private func panel(tokens: WarrenColorTokens) -> some View {
        let menuPalette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        return VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopMenuGroupHeader(title: "OTHER HOSTS")

            ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                panelRow(host, index: index, tokens: tokens)
            }

            if let onAddHost {
                WarrenDesktopMenuDivider()
                // The menu spec's add entry: 12pt grey on a 30pt row, the
                // same as the Host picker's Add SSH host….
                Button(action: onAddHost) {
                    HStack(spacing: WarrenDesktopMenuMetrics.iconSpacing) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: WarrenDesktopMenuMetrics.glyphSlot, height: 12)
                        Text("Add host…")
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isAddHovered ? menuPalette.rowHoverText : menuPalette.addText)
                    .padding(.horizontal, WarrenDesktopMenuMetrics.rowHorizontalPadding)
                    .frame(height: WarrenDesktopMenuMetrics.rowHeight)
                    .contentShape(.rect)
                }
                .buttonStyle(WarrenDesktopMenuRowStyle())
                .onHover { isAddHovered = $0 }
                .warrenSemanticElement(
                    id: "sidebar.other-hosts.add",
                    role: .button,
                    label: "Add host",
                    action: onAddHost
                )
            }
        }
        .warrenMenuSurface(width: nil, shadowY: -12)
        .onHover { inside in
            isPointerInPanel = inside
            if inside {
                timer?.cancel()
            } else {
                scheduleDrop()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switch host")
    }

    private func panelRow(
        _ host: WarrenDesktopSidebarOtherHost,
        index: Int,
        tokens: WarrenColorTokens
    ) -> some View {
        let isHot = index == hotIndex
        return Button { selectHost(at: index) } label: {
            HStack(spacing: 10) {
                WarrenDesktopHostTile(
                    host: host,
                    showsStatus: true,
                    outline: nil,
                    isRaised: false,
                    statusRingTint: tokens.treeRowHover
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isHot ? tokens.treeSessionSelectedText : tokens.treeSessionText)
                    Text(host.panelSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.treeSecondaryText)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !host.marks.isEmpty {
                    WarrenDesktopTreeFoldDots(marks: host.marks)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHot ? tokens.treeRowHover : .clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { setHot(index) } }
        .warrenTooltip("Switch to \(host.name)")
        .accessibilityLabel("Switch to \(host.name)")
        .accessibilityValue(host.needsAttention ? "\(host.panelSubtitle). A session needs you" : host.panelSubtitle)
        .warrenSemanticElement(
            id: "sidebar.other-host.\(host.id)",
            role: .button,
            label: "Switch to \(host.name)",
            value: host.needsAttention ? "A session needs you" : nil,
            action: { selectHost(at: index) }
        )
    }

    // MARK: State

    private func animate(_ change: () -> Void) {
        withAnimation(WarrenDesktopHoverIntent.animation(reduceMotion: reduceMotion), change)
    }

    private func setHot(_ index: Int) {
        animate { hotIndex = index }
    }

    private func lift() {
        guard !isLifted else { return }
        animate {
            isLifted = true
            hotIndex = hotIndex ?? 0
        }
    }

    private func pull() {
        timer?.cancel()
        animate {
            isLifted = true
            isPulled = true
            hotIndex = hotIndex ?? 0
        }
    }

    private func drop() {
        animate {
            isLifted = false
            isPulled = false
            hotIndex = nil
        }
    }

    private func scheduleDrop() {
        schedule {
            try await Task.sleep(for: Metrics.dropDelay)
            if !isPointerInFoot && !isPointerInPanel { drop() }
        }
    }

    private func schedule(_ work: @escaping @MainActor () async throws -> Void) {
        timer?.cancel()
        timer = Task { @MainActor in
            try? await work()
        }
    }

    private func selectHost(at index: Int) {
        guard hosts.indices.contains(index) else { return }
        let id = hosts[index].id
        drop()
        onSelectHost(id)
    }
}

/// A Host's tile: a neutral square ringed in grey with the name's lowercase
/// initial in the monospaced face. A project's avatar is a filled colour
/// square with a bold capital, so the two never read as one another.
struct WarrenDesktopHostTile: View {
    let host: WarrenDesktopSidebarOtherHost
    /// Whether the connection dot sits on the tile's corner.
    let showsStatus: Bool
    /// The surface drawn around the tile, so overlapping tiles stay apart.
    let outline: Color?
    /// Whether the tile casts a shadow, lifted off the foot.
    let isRaised: Bool
    /// A wash over the dot's ring, for a tile on a surface that is itself a
    /// wash over the card.
    var statusRingTint: Color? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    private typealias Metrics = WarrenDesktopSidebarHostStackMetrics

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let shape = RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
        Text(host.initial)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(host.isOnline ? tokens.treeSessionText : tokens.treeChevron)
            .frame(width: Metrics.tileSize, height: Metrics.tileSize)
            .background {
                ZStack {
                    shape.fill(tokens.workbenchCardFill)
                    shape.fill(tokens.treeRowHover)
                }
                .shadow(color: .black.opacity(isRaised ? 0.55 : 0), radius: 5, y: 4)
            }
            .overlay {
                shape.strokeBorder(
                    host.isOnline ? tokens.cardBorderFocused : tokens.cardBorder,
                    lineWidth: 1
                )
            }
            .background {
                if let outline {
                    RoundedRectangle(cornerRadius: Metrics.tileRadius + 1.5, style: .continuous)
                        .fill(outline)
                        .padding(-1.5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(host.isOnline ? tokens.success : tokens.treeQuietText)
                    .frame(width: Metrics.tileDotSize, height: Metrics.tileDotSize)
                    .padding(1.5)
                    .background {
                        ZStack {
                            Circle().fill(tokens.workbenchCardFill)
                            if let statusRingTint {
                                Circle().fill(statusRingTint)
                            }
                        }
                    }
                    .offset(x: 3 + 1.5, y: 3 + 1.5)
                    .opacity(showsStatus ? 1 : 0)
            }
            .accessibilityHidden(true)
    }
}
