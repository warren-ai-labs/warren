import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// What a Session's icon shows.
///
/// An Agent is named by the Session's presented kind, because the Host binds
/// the provider even when it was started inside a shell. Anything else is
/// named by the foreground process the Host probes, so `bun run dev` shows
/// Bun and `cargo test` shows Rust while the shell waits behind them.
///
/// Agent marks are LobeHub's (MIT); program marks are Simple Icons' (CC0).
enum WarrenDesktopAppIcon: Hashable, Sendable {
    case agent(TerminalSessionKind)
    case program(WarrenDesktopProgram)
    case browser

    init(kind: TerminalSessionKind) {
        switch kind {
        case .browser: self = .browser
        case .shell, .custom: self = .program(.zsh)
        case .claude, .codex, .opencode, .pi, .qoder, .antigravity, .trae: self = .agent(kind)
        }
    }

    /// The name a pane header leads with.
    var displayName: String {
        switch self {
        case .agent(let kind): kind.displayName
        case .program(let program): program.displayName
        case .browser: "Browser"
        }
    }

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
            // Anything unknown is drawn as the shell it runs in, never as a
            // blank tile.
            return .program(WarrenDesktopProgram.shell(launchedAs: session.title))
        }
    }

    /// The tile behind the mark: the brand's own colour.
    var tileColor: Color {
        switch self {
        case .program(let program): program.tileColor
        case .browser: Color(warrenHex: 0x3B78C4)
        case .agent(let kind):
            switch kind {
            case .claude: Color(warrenHex: 0xD97757)
            case .codex: Color(warrenHex: 0x5B6CF0)
            // Marks drawn in more than one colour, or in a colour too light
            // for a white glyph, keep their artwork on a near-black tile.
            default: Color(warrenHex: 0x26221F)
            }
        }
    }

    /// Whether the mark is painted white over `tileColor`. Multi-colour
    /// artwork is drawn as authored instead.
    var drawsWhiteGlyph: Bool {
        switch self {
        case .program, .browser: true
        case .agent(let kind):
            switch kind {
            case .claude, .codex, .opencode, .pi: true
            default: false
            }
        }
    }

    /// The artwork in the Desktop bundle's resources, or nil for an SF Symbol.
    var resourceName: String? {
        switch self {
        case .program(let program): program.resourceName
        case .browser: nil
        case .agent(let kind):
            switch kind {
            case .claude: "preset-claude"
            // The white variant, so its inner counter-shape stays a hole when
            // drawn as a template.
            case .codex: "preset-codex-white"
            case .opencode: "preset-opencode"
            case .pi: "preset-pi"
            case .qoder: "preset-qoder"
            case .antigravity: "preset-antigravity"
            case .trae: "preset-trae"
            case .shell, .custom, .browser: nil
            }
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

    /// The shell a Session runs, read from its launch title; zsh, the macOS
    /// default, when the title names no shell.
    static func shell(launchedAs title: String) -> Self {
        switch executableName(title.split(separator: " ").first.map(String.init) ?? "") {
        case "bash", "sh": .bash
        case "fish": .fish
        default: .zsh
        }
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
        case .node: Color(warrenHex: 0x5FA04E)
        case .bun, .deno, .rust: Color(warrenHex: 0x1F1B1A)
        case .npm: Color(warrenHex: 0xCB3837)
        case .pnpm: Color(warrenHex: 0xF69220)
        case .yarn: Color(warrenHex: 0x2C8EBB)
        case .go: Color(warrenHex: 0x00ADD8)
        case .gradle: Color(warrenHex: 0x02303A)
        case .kotlin: Color(warrenHex: 0x7F52FF)
        case .swift: Color(warrenHex: 0xF05138)
        case .python: Color(warrenHex: 0x3776AB)
        case .uv: Color(warrenHex: 0xDE5FE9)
        case .ruby: Color(warrenHex: 0xCC342D)
        case .docker: Color(warrenHex: 0x2496ED)
        case .make: Color(warrenHex: 0x6D00CC)
        case .git: Color(warrenHex: 0xF03C2E)
        case .neovim: Color(warrenHex: 0x57A143)
        case .vim: Color(warrenHex: 0x019733)
        case .zsh: Color(warrenHex: 0xF15A24)
        case .bash: Color(warrenHex: 0x4EAA25)
        case .fish: Color(warrenHex: 0x34C534)
        case .postgres: Color(warrenHex: 0x4169E1)
        case .redis: Color(warrenHex: 0xFF4438)
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

extension Color {
    init(warrenHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
