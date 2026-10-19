import Foundation

/// A Session's plan, folded on this client from its Agent event stream, in the
/// shape the sidebar's second line draws (`plan icon + 3/5`).
///
/// The label wording lives in `WarrenConversation.Plan`; this value only keeps
/// the numbers the row needs so the Desktop package does not depend on the
/// transport's event model.
public struct WarrenDesktopPlanProgress: Hashable, Sendable {
    public let done: Int
    public let total: Int
    /// The plan entry being worked on. Used when the Session is between tool
    /// calls and the tool step alone cannot say what it is doing.
    public let currentStep: String

    public init(done: Int, total: Int, currentStep: String = "") {
        self.done = max(0, done)
        self.total = max(0, total)
        self.currentStep = currentStep
    }
}

/// A shell Session's OSC 133 semantic prompt state, as the Host reports it.
///
/// This is the live state a shell row needs to say what it is doing or last
/// did: whether it is at the prompt or running a command, the command text, its
/// exit code, and when it finished. It is nil when the shell never emitted a
/// marker, which is different from `atPrompt` with nothing run.
public struct WarrenDesktopShellState: Hashable, Sendable {
    public let atPrompt: Bool
    public let runningCommand: String
    public let lastCommand: String
    public let lastExitCode: Int?
    public let lastExitAt: Date?
    /// The shell's own name (`zsh`, `fish`), captured while the foreground
    /// process named a shell. It stays put while a command runs, so the row's
    /// title does not jump to the command's name.
    public let shellName: String
    /// When the running command started, observed by this client at the prompt
    /// transition. Nil when at the prompt or when the start was never seen.
    public let commandStartedAt: Date?

    public init(
        atPrompt: Bool,
        runningCommand: String = "",
        lastCommand: String = "",
        lastExitCode: Int? = nil,
        lastExitAt: Date? = nil,
        shellName: String = "",
        commandStartedAt: Date? = nil
    ) {
        self.atPrompt = atPrompt
        self.runningCommand = runningCommand
        self.lastCommand = lastCommand
        self.lastExitCode = lastExitCode
        self.lastExitAt = lastExitAt
        self.shellName = shellName
        self.commandStartedAt = commandStartedAt
    }

    /// A command is running when the shell is past its prompt.
    public var isRunningCommand: Bool { !atPrompt }

    /// Whether the last command failed. An interrupt (130) or a signal death
    /// (137/143) is not a failure: the person stopped it or the process was
    /// killed, and the design keeps those rows neutral.
    public var didFail: Bool {
        guard let code = lastExitCode, code != 0 else { return false }
        return !Self.interruptedExitCodes.contains(code)
    }

    /// The exit code to show, or nil when there is nothing to add: a success, an
    /// interrupt, a signal death, or no reported status.
    public var displayedExitCode: Int? {
        didFail ? lastExitCode : nil
    }

    static let interruptedExitCodes: Set<Int> = [130, 137, 143]
}

/// A Session's latest context-window reading, for the `88% ctx` reminder.
///
/// The reminder is not a status; it is "this turn is close to compacting", so
/// the row draws it in the quiet amber tier instead of a state colour.
public struct WarrenDesktopContextUsage: Hashable, Sendable {
    public let used: Int
    public let size: Int

    public init(used: Int, size: Int) {
        self.used = max(0, used)
        self.size = max(0, size)
    }

    /// Used share of the window, or nil when the Host has not reported a size.
    public var fraction: Double? {
        guard size > 0 else { return nil }
        return min(1, Double(used) / Double(size))
    }
}

/// One subagent a Session spawned, folded on this client from the parent
/// Session's Agent event stream.
///
/// A subagent is a child of the Session rather than a Session of its own: its
/// events ride the parent's stream tagged with `payload.subagentId`, so the
/// sidebar draws it as an expandable child row instead of a navigable Session.
public struct WarrenDesktopSubagent: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case running
        case completed
    }

    /// The child's stable identity: Claude's `agentId`, Codex's `agent_id`.
    public let id: String
    /// The tool call that spawned it, when the Host linked the row to one.
    public let parentCallID: String?
    public let title: String
    public let summary: String
    public let state: State
    /// The most recent tool activity of the child's own transcript, one line.
    public let lastActivity: String?
    /// Whether the child is waiting on a person. The Host lifts a child's
    /// pending question or approval to the parent's attention, and the client
    /// folds the same sidechain interaction here so the row can name which
    /// child is asking and reveal just that one.
    ///
    /// No provider reaches this today, so the reveal it drives stays dark:
    /// Claude persists no question or permission inside a subagent transcript,
    /// and Codex runs its child threads with approval disabled and keeps
    /// approval requests out of the rollout. The fold is kept because it is the
    /// client half of a contract the Host already honors — a child that starts
    /// asking will light up both ends with no change here.
    public let isWaiting: Bool

    public init(
        id: String,
        parentCallID: String? = nil,
        title: String,
        summary: String = "",
        state: State = .running,
        lastActivity: String? = nil,
        isWaiting: Bool = false
    ) {
        self.id = id
        self.parentCallID = parentCallID
        self.title = title
        self.summary = summary
        self.state = state
        self.lastActivity = lastActivity
        self.isWaiting = isWaiting
    }

    public var isRunning: Bool { state == .running }
}
