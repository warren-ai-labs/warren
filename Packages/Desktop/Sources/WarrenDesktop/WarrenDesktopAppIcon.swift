import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// What a pane is running, as far as its icon is concerned.
///
/// An Agent is named by the Session's presented kind, because the Host binds
/// the provider even when it was started inside a shell. Anything else is
/// named by the foreground process the Host probes, so `bun run dev` shows
/// Bun and `cargo test` shows Rust while the shell waits behind them.
enum WarrenDesktopAppIcon: Hashable, Sendable {
    case agent(TerminalSessionKind)
    case program(WarrenDesktopProgram)
    case browser
    /// A shell Warren cannot name, or a process with no artwork. Drawn with
    /// Warren's own shell glyph, never as an empty tile.
    case shell

    static func resolve(_ session: WarrenDesktopSession) -> Self {
        switch session.presentedKind {
        case .browser:
            return .browser
        case .claude, .codex, .opencode, .pi, .qoder, .antigravity, .trae:
            return .agent(session.presentedKind)
        case .shell, .custom:
            if let program = WarrenDesktopProgram.resolve(
                process: session.runtimeProcess,
                commandLine: session.runtimeCommandLine
            ) {
                return .program(program)
            }
            return .shell
        }
    }
}

/// Programs Warren has artwork for. Marks come from Simple Icons (CC0) and are
/// drawn as a white glyph on the brand's own color.
enum WarrenDesktopProgram: String, CaseIterable, Hashable, Sendable {
    case node, bun, deno, npm, pnpm, yarn
    case go, rust, gradle, kotlin, swift, python, uv, ruby
    case docker, make, git, neovim, vim
    case zsh, bash, fish
    case postgres, redis

    /// Maps a foreground process to its artwork.
    ///
    /// Several tools have no mark of their own and borrow their ecosystem's:
    /// `npx` is npm, `cargo` is Rust, `gradlew` is Gradle. Interpreters that
    /// run a package manager's script (`node …/npm-cli.js`) are read from the
    /// command line's first word when the process name alone is the runtime.
    static func resolve(process: String, commandLine: String) -> Self? {
        let name = Self.executableName(process)
        if let program = Self.byExecutable[name] {
            if program == .node || program == .python,
               let launcher = Self.executableName(
                   commandLine.split(separator: " ").first.map(String.init) ?? ""
               ).nilIfEmpty,
               let refined = Self.byExecutable[launcher] {
                return refined
            }
            return program
        }
        if name.hasPrefix("python") { return .python }
        return nil
    }

    private static func executableName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        // Login shells report themselves as `-zsh`.
        return last.hasPrefix("-") ? String(last.dropFirst()).lowercased() : last.lowercased()
    }

    private static let byExecutable: [String: Self] = [
        "node": .node, "tsx": .node, "ts-node": .node,
        "bun": .bun, "bunx": .bun,
        "deno": .deno,
        "npm": .npm, "npx": .npm,
        "pnpm": .pnpm, "pnpx": .pnpm,
        "yarn": .yarn,
        "go": .go, "gopls": .go, "air": .go,
        "cargo": .rust, "rustc": .rust, "rustup": .rust,
        "gradle": .gradle, "gradlew": .gradle,
        "kotlin": .kotlin, "kotlinc": .kotlin,
        "swift": .swift, "swift-build": .swift, "swift-test": .swift, "xcodebuild": .swift,
        "python": .python, "python3": .python, "pip": .python, "pip3": .python,
        "pytest": .python, "ipython": .python,
        "uv": .uv, "uvx": .uv,
        "ruby": .ruby, "irb": .ruby, "bundle": .ruby, "rails": .ruby,
        "docker": .docker, "docker-compose": .docker,
        "make": .make, "gmake": .make,
        "git": .git, "lazygit": .git, "tig": .git,
        "nvim": .neovim, "vim": .vim, "vi": .vim,
        "zsh": .zsh, "bash": .bash, "sh": .bash, "fish": .fish,
        "psql": .postgres, "postgres": .postgres,
        "redis-cli": .redis, "redis-server": .redis,
    ]

    var resourceName: String {
        switch self {
        case .node: "program-nodedotjs"
        case .bun: "program-bun"
        case .deno: "program-deno"
        case .npm: "program-npm"
        case .pnpm: "program-pnpm"
        case .yarn: "program-yarn"
        case .go: "program-go"
        case .rust: "program-rust"
        case .gradle: "program-gradle"
        case .kotlin: "program-kotlin"
        case .swift: "program-swift"
        case .python: "program-python"
        case .uv: "program-uv"
        case .ruby: "program-ruby"
        case .docker: "program-docker"
        case .make: "program-make"
        case .git: "program-git"
        case .neovim: "program-neovim"
        case .vim: "program-vim"
        case .zsh: "program-zsh"
        case .bash: "program-gnubash"
        case .fish: "program-fishshell"
        case .postgres: "program-postgresql"
        case .redis: "program-redis"
        }
    }

    /// The brand color the tile is filled with. Marks whose brand is pure
    /// black are lifted to a near-black so the tile still has an edge on Ember.
    var tileColor: Color {
        switch self {
        case .node: Color(hex: 0x5FA04E)
        case .bun, .deno, .rust: Color(hex: 0x1F1B1A)
        case .npm: Color(hex: 0xCB3837)
        case .pnpm: Color(hex: 0xF69220)
        case .yarn: Color(hex: 0x2C8EBB)
        case .go: Color(hex: 0x00ADD8)
        case .gradle: Color(hex: 0x02303A)
        case .kotlin: Color(hex: 0x7F52FF)
        case .swift: Color(hex: 0xF05138)
        case .python: Color(hex: 0x3776AB)
        case .uv: Color(hex: 0xDE5FE9)
        case .ruby: Color(hex: 0xCC342D)
        case .docker: Color(hex: 0x2496ED)
        case .make: Color(hex: 0x6D00CC)
        case .git: Color(hex: 0xF03C2E)
        case .neovim: Color(hex: 0x57A143)
        case .vim: Color(hex: 0x019733)
        case .zsh: Color(hex: 0xF15A24)
        case .bash: Color(hex: 0x4EAA25)
        case .fish: Color(hex: 0x34C534)
        case .postgres: Color(hex: 0x4169E1)
        case .redis: Color(hex: 0xFF4438)
        }
    }

    var displayName: String {
        switch self {
        case .node: "Node.js"
        case .bun: "Bun"
        case .deno: "Deno"
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .yarn: "Yarn"
        case .go: "Go"
        case .rust: "Rust"
        case .gradle: "Gradle"
        case .kotlin: "Kotlin"
        case .swift: "Swift"
        case .python: "Python"
        case .uv: "uv"
        case .ruby: "Ruby"
        case .docker: "Docker"
        case .make: "Make"
        case .git: "Git"
        case .neovim: "Neovim"
        case .vim: "Vim"
        case .zsh: "zsh"
        case .bash: "bash"
        case .fish: "fish"
        case .postgres: "PostgreSQL"
        case .redis: "Redis"
        }
    }
}

/// One app icon on a rounded tile: the unit tabs stack and sidebar lines lead
/// with.
///
/// The tile is the same shape whatever it holds, so a stack of mixed agents and
/// programs reads as one row of app icons. Agents keep their authored artwork
/// on a quiet tile; programs are a white mark on their brand color.
struct WarrenDesktopAppIconTile: View {
    let icon: WarrenDesktopAppIcon
    var size: CGFloat = WarrenLayoutMetrics.tabIconTileSize

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    private var cornerRadius: CGFloat { size * 0.28 }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(background(tokens))
            artwork(tokens)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    private func background(_ tokens: WarrenColorTokens) -> Color {
        switch icon {
        case .program(let program): program.tileColor
        case .agent, .browser, .shell: tokens.muted
        }
    }

    @ViewBuilder
    private func artwork(_ tokens: WarrenColorTokens) -> some View {
        let glyph = size * 0.62
        switch icon {
        case .program(let program):
            if let image = WarrenPresetIconCache.shared.image(named: program.resourceName, template: true) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .frame(width: glyph, height: glyph)
            } else {
                Text(String(program.displayName.prefix(1)))
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        case .agent(let kind):
            if let preset = WarrenDesktopSessionPreset.builtIn(for: kind) {
                WarrenDesktopPresetIcon(preset: preset)
                    .frame(width: glyph, height: glyph)
            } else {
                shellGlyph(tokens)
            }
        case .browser:
            if let preset = WarrenDesktopSessionPreset.builtIn(for: .browser) {
                WarrenDesktopPresetIcon(preset: preset)
                    .frame(width: glyph, height: glyph)
            } else {
                shellGlyph(tokens)
            }
        case .shell:
            shellGlyph(tokens)
        }
    }

    private func shellGlyph(_ tokens: WarrenColorTokens) -> some View {
        Image(systemName: "terminal")
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tokens.mutedForeground)
    }
}

/// Up to three tiles overlapped, for a tab that holds a split group.
struct WarrenDesktopAppIconStack: View {
    let icons: [WarrenDesktopAppIcon]
    var size: CGFloat = WarrenLayoutMetrics.tabIconTileSize
    /// The surface behind the stack, used for the ring that separates tiles.
    var ringColor: Color

    static let maximumVisible = 3

    var body: some View {
        HStack(spacing: -WarrenLayoutMetrics.tabIconStackOverlap) {
            ForEach(Array(icons.prefix(Self.maximumVisible).enumerated()), id: \.offset) { index, icon in
                WarrenDesktopAppIconTile(icon: icon, size: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.28 + 1.5, style: .continuous)
                            .fill(ringColor)
                            .padding(-1.5)
                    )
                    .zIndex(Double(Self.maximumVisible - index))
            }
        }
        .accessibilityHidden(true)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
