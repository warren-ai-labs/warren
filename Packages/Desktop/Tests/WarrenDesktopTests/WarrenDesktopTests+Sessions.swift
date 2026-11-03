import XCTest
import SwiftUI
import AppKit
import Combine
@testable import WarrenDesktop
import WarrenDesktopFixtures
import WarrenDesignSystem
import WarrenDomain
import WarrenClientCore
import WarrenObservation

extension WarrenDesktopTests {
    /// The second line: a working Session says what it is doing, a resting one
    /// says what this turn did, and one that has done nothing says so rather
    /// than leaving a gap.
    func testSessionSecondLineLeadsWithTheOneThingThatMatters() {
        let workspaceID = WorkspaceID()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        let working = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Claude Code",
            customTitle: "Ghostty resize",
            kind: .claude,
            activity: .working,
            activityUpdatedAt: now.addingTimeInterval(-30),
            currentStep: "Running git status",
            lastActivity: "Ran swift test",
            turnStartedAt: now.addingTimeInterval(-18)
        )
        let running = WarrenDesktopWorkspaceSessionRow.secondLine(for: working, now: now)
        XCTAssertEqual(running.tone, .running)
        XCTAssertEqual(
            running.primary,
            "Running git status",
            "What it is doing outranks what it last did"
        )
        XCTAssertEqual(
            running.meta,
            .time("18s"),
            "A running row without a plan shows how long this turn has run"
        )

        let counted = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Claude Code",
            customTitle: "Ghostty resize",
            kind: .claude,
            activity: .ready,
            activityUpdatedAt: now.addingTimeInterval(-42 * 60),
            lastActivity: "Read 2 files",
            turnCounts: ["Edited 3 files", "Ran 5 commands"]
        )
        let resting = WarrenDesktopWorkspaceSessionRow.secondLine(for: counted, now: now)
        XCTAssertEqual(resting.tone, .done, "A finished turn not yet seen keeps the brighter ink")
        XCTAssertEqual(
            resting.primary,
            "Edited 3 files",
            "The heaviest count leads a resting row"
        )
        XCTAssertEqual(
            resting.extras.map(\.text),
            ["Ran 5 commands"],
            "The second count is the one append a resting row has"
        )
        XCTAssertEqual(resting.meta, .time("42m"), "A resting row shows how long ago it was")

        let plain = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Claude Code",
            kind: .claude,
            activity: .ready,
            lastActivity: "Read 2 files"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: plain, now: now).primary,
            "Read 2 files",
            "A turn that counted nothing falls back to the last action"
        )

        let fresh = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            title: "Shell",
            kind: .shell
        )
        let untouched = WarrenDesktopWorkspaceSessionRow.secondLine(for: fresh, now: now)
        XCTAssertEqual(untouched.primary, "New session")
        XCTAssertEqual(untouched.meta, .none)
        XCTAssertNil(untouched.announcement)
    }
    /// A shell row falls back to the command in the foreground; the Host keeps
    /// no history, so that is what there is to show.
    func testSessionSecondLineShellUsesTheForegroundCommand() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            customTitle: "Logs",
            kind: .shell,
            runtimeProcess: "head",
            runtimeCommandLine: "head -100 /Users/x/relay.log"
        )
        XCTAssertEqual(
            WarrenDesktopWorkspaceSessionRow.secondLine(for: session).primary,
            "head -100 /Users/x/relay.log"
        )
    }
    /// An append is added only when the primary and that whole append fit, and
    /// the first one that does not fit stops the rest.
    func testSessionSecondLineFitAppendsOnlyWholeSegments() {
        let line = WarrenDesktopSessionSecondLine(
            tone: .running,
            primary: "Running swift build",
            extras: [
                .init(text: "88% ctx", isWarning: true),
                .init(text: "1m 12s"),
                .init(text: "Edited 2 files"),
            ],
            meta: .plan(done: 3, total: 5)
        )
        let wide = WarrenDesktopSessionSecondLineLayout.fit(line: line, availableWidth: 400)
        XCTAssertEqual(wide.extras.count, 3, "A wide row takes every append")
        XCTAssertFalse(wide.isPrimaryTruncated)

        let narrow = WarrenDesktopSessionSecondLineLayout.fit(line: line, availableWidth: 140)
        XCTAssertEqual(narrow.extras, [], "A narrow row appends nothing and fades the primary")
        XCTAssertTrue(narrow.isPrimaryTruncated)

        func width(primary: CGFloat, appends: [CGFloat], meta: CGFloat) -> CGFloat {
            meta + WarrenDesktopSessionSecondLineLayout.primaryMetaSpacing
                + primary + appends.reduce(0, +)
        }
        let primary = WarrenDesktopSessionSecondLineLayout.textWidth(
            "Running swift build",
            fontSize: WarrenDesktopSessionSecondLineLayout.primaryFontSize,
            monospaced: false
        )
        let first = WarrenDesktopSessionSecondLineLayout.separatorWidth + WarrenDesktopSessionSecondLineLayout.textWidth(
            "88% ctx",
            fontSize: WarrenDesktopSessionSecondLineLayout.primaryFontSize,
            monospaced: false
        )
        let second = WarrenDesktopSessionSecondLineLayout.separatorWidth + WarrenDesktopSessionSecondLineLayout.textWidth(
            "1m 12s",
            fontSize: WarrenDesktopSessionSecondLineLayout.primaryFontSize,
            monospaced: false
        )
        let meta = WarrenDesktopSessionSecondLineLayout.metaWidth(of: line.meta)
        let one = WarrenDesktopSessionSecondLineLayout.fit(
            line: line,
            availableWidth: width(primary: primary, appends: [first], meta: meta)
        )
        XCTAssertEqual(one.extras.map(\.text), ["88% ctx"], "Exactly one append fits")
        let stillOne = WarrenDesktopSessionSecondLineLayout.fit(
            line: line,
            availableWidth: width(primary: primary, appends: [first, second], meta: meta) - 1
        )
        XCTAssertEqual(
            stillOne.extras.map(\.text),
            ["88% ctx"],
            "The append that does not fit stops the rest instead of skipping ahead"
        )
    }
    /// The working row's drift crosses the line and then rests, so the eye is
    /// never offered a loop to settle on.
    func testActivityShimmerSweepsThenRests() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let period = WarrenDesktopActivityShimmer.period
        XCTAssertEqual(
            WarrenDesktopActivityShimmer.center(at: start),
            WarrenDesktopActivityShimmer.center(at: start.addingTimeInterval(period)),
            "One cycle is one cycle"
        )
        let entering = WarrenDesktopActivityShimmer.center(at: start)
        let middle = WarrenDesktopActivityShimmer.center(at: start.addingTimeInterval(period / 2))
        let leaving = WarrenDesktopActivityShimmer.center(
            at: start.addingTimeInterval(period * WarrenDesktopActivityShimmer.sweepShare)
        )
        XCTAssertEqual(
            entering,
            1 + WarrenDesktopActivityShimmer.bandWidth / 2,
            accuracy: 0.0001,
            "The band starts just past the line's right edge"
        )
        XCTAssertGreaterThan(entering, middle)
        XCTAssertGreaterThan(middle, leaving)
        XCTAssertEqual(
            leaving,
            -WarrenDesktopActivityShimmer.bandWidth / 2,
            accuracy: 0.0001,
            "The band comes to rest just past the line's left edge"
        )
        XCTAssertEqual(
            WarrenDesktopActivityShimmer.center(
                at: start.addingTimeInterval(period * WarrenDesktopActivityShimmer.sweepShare + 1)
            ),
            leaving,
            accuracy: 0.0001,
            "The rest of the cycle holds still"
        )
        XCTAssertEqual(WarrenDesktopActivityShimmer.smoothstep(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(WarrenDesktopActivityShimmer.smoothstep(-1), 0, accuracy: 0.0001)
        XCTAssertEqual(WarrenDesktopActivityShimmer.smoothstep(2), 1, accuracy: 0.0001)
    }
    func testExternalIDEOptionsEnableOnlyInstalledApplicationsForLocalWorkspace() {
        let projectID = ProjectID()
        let workspace = Workspace(
            projectID: projectID,
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let codeURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { bundleIdentifier in
                bundleIdentifier == "com.microsoft.VSCode" ? codeURL : nil
            },
            directoryExists: { $0.path == workspace.path },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        let options = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertEqual(options.map(\.id), ["visualStudioCode"])
        XCTAssertEqual(options.map(\.isEnabled), [true])
        XCTAssertEqual(options.first?.workspaceURL?.path, workspace.path)
        XCTAssertEqual(options.first?.applicationURL, codeURL)
    }
    func testExternalIDEOptionsDisableEveryApplicationForRemoteWorkspace() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Remote",
            path: "/srv/warren"
        )
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in URL(fileURLWithPath: "/Applications/IDE.app") },
            directoryExists: { _ in true },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        let options = service.options(for: workspace, isLocalEndpoint: false)

        XCTAssertEqual(options.count, WarrenDesktopExternalIDE.supported.count)
        XCTAssertTrue(options.allSatisfy { !$0.isEnabled })
    }
    func testExternalIDEOptionsDisableEveryApplicationWithoutExistingWorkspaceDirectory() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Missing",
            path: "/missing/worktree"
        )
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in URL(fileURLWithPath: "/Applications/IDE.app") },
            directoryExists: { _ in false },
            launch: { _, _ in XCTFail("Availability must not launch an IDE") }
        )

        XCTAssertTrue(
            service.options(for: workspace, isLocalEndpoint: true)
                .allSatisfy { !$0.isEnabled }
        )
        XCTAssertTrue(
            service.options(for: nil, isLocalEndpoint: true)
                .allSatisfy { !$0.isEnabled }
        )
    }
    func testExternalIDEServiceLaunchesWorkspaceWithResolvedApplication() async throws {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var launchedWorkspaceURL: URL?
        var launchedApplicationURL: URL?
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in applicationURL },
            directoryExists: { _ in true },
            launch: { workspaceURL, resolvedApplicationURL in
                launchedWorkspaceURL = workspaceURL
                launchedApplicationURL = resolvedApplicationURL
            }
        )
        let option = try XCTUnwrap(
            service.options(for: workspace, isLocalEndpoint: true)
                .first { $0.id == "goLand" }
        )

        try await service.open(option)

        XCTAssertEqual(launchedWorkspaceURL?.path, workspace.path)
        XCTAssertEqual(launchedApplicationURL, applicationURL)
    }
    func testExternalIDEOptionsCacheInvalidatesWhenWorkspaceDirectoryChanges() {
        let workspace = Workspace(
            projectID: ProjectID(),
            name: "Feature",
            path: "/Users/me/Workspace/warren-feature"
        )
        let applicationURL = URL(fileURLWithPath: "/Applications/GoLand.app")
        var directoryExists = true
        var resolveCount = 0
        let service = WarrenDesktopExternalIDEService(
            resolveApplicationURL: { _ in
                resolveCount += 1
                return applicationURL
            },
            directoryExists: { _ in directoryExists },
            launch: { _, _ in }
        )

        let availableOptions = service.options(for: workspace, isLocalEndpoint: true)
        directoryExists = false
        let unavailableOptions = service.options(for: workspace, isLocalEndpoint: true)

        XCTAssertTrue(availableOptions.allSatisfy(\.isEnabled))
        XCTAssertTrue(unavailableOptions.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(resolveCount, WarrenDesktopExternalIDE.supported.count * 2)
    }
    func testConnectionPresentationNamesRuntimeMigration() {
        let migrating = WarrenDesktopConnectionPresentation(
            .connecting,
            migratingRuntimeSessions: true
        )

        XCTAssertEqual(migrating.label, "Migrating runtime sessions…")
        XCTAssertEqual(migrating.tone, .info)
        XCTAssertTrue(migrating.isActive)
    }
    func testWorkspaceEditorStateStoresOnlyEnabledMarkers() {
        let suiteName = "warren-workspace-editor-enabled-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var states: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState] = [:]
        for (host, enabled) in [("local", true), ("local", false), ("remote", true)] {
            let state = WarrenDesktopWorkspaceEditorState(
                hostId: host,
                workspaceId: WorkspaceID(),
                enabled: enabled
            )
            states[WarrenDesktopWorkspaceEditorStateStore.key(for: state)] = state
        }

        // A disabled marker is not a record: it is the absence of one, so
        // forgetting a Workspace leaves nothing behind to restore.
        WarrenDesktopWorkspaceEditorStateStore.save(states, defaults: defaults)
        let restored = WarrenDesktopWorkspaceEditorStateStore.restore(defaults: defaults)
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored.values.allSatisfy(\.enabled))

        // Clearing every marker removes the value rather than leaving an empty
        // one behind.
        WarrenDesktopWorkspaceEditorStateStore.save([:], defaults: defaults)
        XCTAssertTrue(
            WarrenDesktopWorkspaceEditorStateStore.restore(defaults: defaults).isEmpty
        )
    }
    func testWorkspaceEditorStateMigratesLegacyContentModeSelection() {
        let suiteName = "warren-workspace-editor-migration-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspaceID = WorkspaceID()
        let legacyKey = "warren.desktop.workspaceContentModes.local"
        defaults.set([workspaceID.description], forKey: legacyKey)

        let migrated = WarrenDesktopWorkspaceEditorStateStore
            .restoreMigratingLegacyContentModes(scope: "local", defaults: defaults)

        let key = WarrenDesktopWorkspaceEditorKey(
            hostId: "local",
            workspaceId: workspaceID
        )
        XCTAssertEqual(migrated[key]?.enabled, true)
        // The legacy key is retired, so the migration does not repeat and cannot
        // resurrect a marker the user later forgot.
        XCTAssertNil(defaults.stringArray(forKey: legacyKey))
        XCTAssertEqual(
            WarrenDesktopWorkspaceEditorStateStore.restore(defaults: defaults)[key]?.enabled,
            true
        )
    }
    func testBuiltInPresetsMapToExplicitLaunchRequests() {
        XCTAssertEqual(WarrenDesktopSessionPreset.pinned.map(\.id), ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "trae", "browser"])
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.map(\.presetBarTitle),
            ["Shell", "Claude", "Codex", "OpenCode", "Pi", "Qoder", "Antigravity", "Trae", "Browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.compactMap(\.presetBarIconName),
            ["preset-shell", "preset-claude", "preset-codex", "preset-opencode", "preset-pi", "preset-qoder", "preset-antigravity", "preset-trae", "preset-browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.pinned.map(\.request),
            [
                .shell, .claude, .codex, .opencode, .pi, .qoder, .antigravity, .trae, TerminalSessionLaunchRequest(kind: .browser),
            ]
        )
        XCTAssertNil(TerminalSessionLaunchRequest.shell.command)
        XCTAssertEqual(TerminalSessionLaunchRequest.claude.command, "claude")
        // Built-in presets carry no user title: the Host derives the default
        // display name from the kind and keeps the custom-title slot free for
        // automatic AI title generation. The launch title is presentation copy
        // owned by the preset catalog, not a session custom title.
        XCTAssertNil(TerminalSessionLaunchRequest.claude.title)
        XCTAssertEqual(
            TerminalSessionLaunchRequest.codex.command,
            "codex --dangerously-bypass-hook-trust"
        )
        XCTAssertEqual(TerminalSessionLaunchRequest.opencode.command, "opencode")
        XCTAssertNil(TerminalSessionLaunchRequest.opencode.title)
        XCTAssertEqual(TerminalSessionLaunchRequest.pi.command, "pi")
        XCTAssertNil(TerminalSessionLaunchRequest.pi.title)
        XCTAssertEqual(TerminalSessionLaunchRequest.qoder.command, "qoder")
        XCTAssertNil(TerminalSessionLaunchRequest.qoder.title)
        XCTAssertEqual(TerminalSessionLaunchRequest.trae.command, "trae-cli interactive")
        XCTAssertEqual(WarrenDesktopSessionPreset.firstAI?.id, "claude")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.firstAI?
                .resolvedRequest(commandOverride: "claude --model sonnet").command,
            "claude --model sonnet"
        )
        // The command override keeps the preset title slot untouched (nil for
        // built-ins), so no preset name leaks into the custom-title slot.
        XCTAssertNil(
            WarrenDesktopSessionPreset.pinned.first { $0.id == "codex" }?
                .resolvedRequest(commandOverride: "codex --model gpt-5").title
        )
    }
    func testPresetOrderNormalizesPersistedIdentifiers() {
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrder("codex,shell,codex,future"),
            ["codex", "shell", "claude", "opencode", "pi", "qoder", "antigravity", "trae", "browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrder(""),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "trae", "browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.normalizedOrderRawValue("codex,shell,codex,future"),
            "codex,shell,claude,opencode,pi,qoder,antigravity,trae,browser"
        )
    }
    func testPresetOrderControlsPresentation() {
        let order = "shell,codex,claude,opencode,pi,qoder,antigravity,trae,browser"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedPinned(by: order).map(\.id),
            ["shell", "codex", "claude", "opencode", "pi", "qoder", "antigravity", "trae", "browser"]
        )
        XCTAssertEqual(WarrenDesktopSessionPreset.firstAI(orderedBy: order)?.id, "codex")
    }
    func testPresetVisibilityHidesTraeByDefaultAndControlsAutomaticAI() {
        XCTAssertEqual(WarrenDesktopSessionPreset.defaultHiddenRawValue, "trae")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedVisible(
                by: WarrenDesktopSessionPreset.defaultOrderRawValue,
                hidden: WarrenDesktopSessionPreset.defaultHiddenRawValue
            ).map(\.id),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "browser"]
        )

        let onlyTraeVisible = WarrenDesktopSessionPreset.pinned
            .map(\.id)
            .filter { $0 != "trae" }
            .joined(separator: ",")
        XCTAssertEqual(
            WarrenDesktopSessionPreset.firstAI(
                orderedBy: "trae,shell,claude,codex",
                hidden: onlyTraeVisible
            )?.id,
            "trae"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.settingVisibility(of: "trae", visible: true, in: "trae"),
            ""
        )
    }
    /// Only a local endpoint can show the page a browser Session draws, so a
    /// remote Host must not offer the preset. The preference is untouched: the
    /// preset returns when the endpoint does.
    func testBrowserPresetIsOfferedOnlyWhereItsPageCanBeSeen() {
        let order = WarrenDesktopSessionPreset.defaultOrderRawValue
        let hidden = WarrenDesktopSessionPreset.defaultHiddenRawValue

        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedLaunchable(
                by: order,
                hidden: hidden,
                embeddedBrowser: true
            ).map(\.id),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity", "browser"]
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.orderedLaunchable(
                by: order,
                hidden: hidden,
                embeddedBrowser: false
            ).map(\.id),
            ["shell", "claude", "codex", "opencode", "pi", "qoder", "antigravity"]
        )
        XCTAssertFalse(
            WarrenDesktopSessionPreset.normalizedHidden(hidden).contains("browser"),
            "Endpoint capability must not be recorded as a hidden-preset preference"
        )
    }
    func testPresetLaunchFeedbackDisablesDuplicateStarts() {
        XCTAssertFalse(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: true, isBusy: false, isPending: false))
        XCTAssertTrue(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: true, isBusy: true, isPending: false))
        XCTAssertTrue(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: true, isBusy: false, isPending: true))
        XCTAssertTrue(WarrenDesktopPresetLaunchFeedback.isDisabled(hasScope: false, isBusy: false, isPending: false))
        XCTAssertEqual(WarrenDesktopPresetLaunchFeedback.label(isPending: true), "Starting…")
        XCTAssertEqual(WarrenDesktopPresetLaunchFeedback.label(isPending: false), "Ready")
    }
    func testEveryPresetAcceptsItsOwnCommandOverride() {
        // A Chat preset has no command: the Host picks the provider's ACP server.
        for preset in WarrenDesktopSessionPreset.pinned where preset.request.kind != .browser && !preset.request.isConversation {
            XCTAssertEqual(
                preset.resolvedRequest(commandOverride: "personal-\(preset.id)").command,
                "personal-\(preset.id)"
            )
        }
        let trae = WarrenDesktopSessionPreset.pinned.first { $0.id == "trae" }
        XCTAssertEqual(trae?.resolvedRequest(commandOverride: "").command, "trae-cli interactive")
    }
    /// A browser Session has no command line: the Host launches Chromium
    /// itself. A typed override must not reach the launch request, or the
    /// preset would promise a command nothing runs.
    func testBrowserPresetIgnoresCommandOverrides() {
        let browser = WarrenDesktopSessionPreset.pinned.first { $0.id == "browser" }
        XCTAssertEqual(browser?.request.kind, .browser)
        XCTAssertNil(browser?.request.command)
        XCTAssertNil(browser?.resolvedRequest(commandOverride: "chromium --headless").command)
        XCTAssertNil(browser?.resolvedRequest(commandOverride: "").command)
        XCTAssertEqual(browser?.createButtonTitle, "Open Browser")
        XCTAssertFalse(browser?.isAI ?? true)
    }
    func testAutomaticShellPolicyIsOptInForAnEmptyWorkspace() {
        let fixture = WarrenDesktopFixture.preview
        let emptyWorkspaceID = fixture.groups[0].workspaces[1].id
        let action = WarrenDesktopAction.openWorkspace(emptyWorkspaceID)

        XCTAssertNil(WarrenDesktopAutomaticSessionPolicy.workspaceID(
            for: action,
            in: fixture.projection,
            creatingWorkspaceIDs: [],
            autoOpenShell: false
        ))
        XCTAssertEqual(
            WarrenDesktopAutomaticSessionPolicy.workspaceID(
                for: action,
                in: fixture.projection,
                creatingWorkspaceIDs: [],
                autoOpenShell: true
            ),
            emptyWorkspaceID
        )
    }
    func testPresetOrderMovesWithinBounds() {
        let order = "shell,claude,codex,opencode,pi,qoder,antigravity,trae,browser"

        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("codex", by: -1, in: order),
            "shell,codex,claude,opencode,pi,qoder,antigravity,trae,browser"
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("shell", by: -1, in: order),
            order
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("browser", by: 1, in: order),
            order
        )
        XCTAssertEqual(
            WarrenDesktopSessionPreset.moving("trae", by: 1, in: order),
            "shell,claude,codex,opencode,pi,qoder,antigravity,browser,trae"
        )
    }
    func testSessionDisplayTitlePrefersCustomTitle() {
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Shell",
            customTitle: "My Agent"
        )
        XCTAssertEqual(session.displayTitle, "My Agent")

        let defaultSession = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: WorkspaceID(),
            title: "Codex"
        )
        XCTAssertEqual(defaultSession.displayTitle, "Codex")
    }
    func testPresetIconCacheLoadsHitsAndMissesOnlyOnce() {
        var loads: [String] = []
        let expected = NSImage(size: NSSize(width: 12, height: 12))
        let cache = WarrenPresetIconCache { name in
            loads.append(name)
            return name == "known" ? expected : nil
        }

        XCTAssertTrue(cache.image(named: "known") === expected)
        XCTAssertTrue(cache.image(named: "known") === expected)
        XCTAssertNil(cache.image(named: "missing"))
        XCTAssertNil(cache.image(named: "missing"))
        XCTAssertEqual(loads, ["known", "missing"])
    }
    func testPackagedPresetIconsAreValidImages() throws {
        let iconNames = try WarrenDesktopSessionPreset.pinned.map {
            try XCTUnwrap($0.presetBarIconName)
        } + ["preset-codex-white"]

        for iconName in iconNames {
            let image = try XCTUnwrap(WarrenPresetIconCache.shared.image(named: iconName))
            XCTAssertTrue(image.isValid, "Expected \(iconName) to decode as a valid image")
        }
    }
    /// The cache marks an image as a template on first load and then hands that
    /// same instance to everyone, so a tintable icon must not be reachable under
    /// a name that also serves an untinted one.
    func testPresetIconCacheAppliesTemplateFlagOnFirstLoad() {
        let cache = WarrenPresetIconCache { _ in NSImage(size: NSSize(width: 12, height: 12)) }

        XCTAssertEqual(cache.image(named: "tinted", template: true)?.isTemplate, true)
        XCTAssertEqual(cache.image(named: "brand")?.isTemplate, false)
    }
    /// Only the single-color glyphs are tinted. A brand mark's color is its
    /// identity, so tinting one would erase it — and Codex's mark is two-tone,
    /// which a template mask would flatten into a solid blob.
    func testOnlySingleColorPresetGlyphsAreTinted() {
        let tintable = Set(
            WarrenDesktopSessionPreset.pinned
                .filter(\.presetBarIconIsTintable)
                .map(\.id)
        )

        XCTAssertEqual(tintable, ["shell", "opencode", "pi", "browser"])
        for brand in ["claude", "codex", "qoder", "antigravity", "trae"] {
            XCTAssertFalse(tintable.contains(brand), "\(brand) is a brand mark")
        }
    }
    func testWorkspaceActivityUsesMostActionableSessionState() {
        let fixture = WarrenDesktopFixture.preview
        let workspaceID = fixture.groups[0].workspaces[0].id
        let working = fixture.sessions[0]
        let failed = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "failed",
            title: "Failed",
            kind: .codex,
            state: .failed,
            activity: .failed
        )
        let waiting = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspaceID,
            tabID: "waiting",
            title: "Waiting",
            kind: .claude,
            activity: .blocked
        )
        let projection = WarrenDesktopProjection(
            host: fixture.host,
            groups: fixture.groups,
            sessions: [working, waiting, failed]
        )

        XCTAssertEqual(projection.activity(in: workspaceID), .failed)
        XCTAssertEqual(projection.workspaceActivities[workspaceID], .failed)
        XCTAssertEqual(
            projection.workspaceActivitySummaries[workspaceID]?.activeTabCount,
            0
        )
        XCTAssertEqual(projection.session(id: failed.id), failed)
    }
    @MainActor
    func testRichWorkspaceRowsShowEveryLiveSessionAsALeaf() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        let codex = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            tabID: "tab.codex",
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let claude = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Review API",
            kind: .claude,
            activity: .ready
        )
        // A shell the Host promoted through an Agent binding reports activity.
        let promotedShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Bound shell",
            kind: .shell,
            activity: .working
        )
        // A shell with no Agent binding reports no activity, but it is still a
        // live Session and therefore still a leaf of the tree.
        let plainShell = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Plain shell",
            kind: .shell
        )
        let ended = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Ended",
            kind: .codex,
            state: .exited,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace],
            sessions: [codex, claude, promotedShell, plainShell, ended]
        )
        let recorder = WarrenSemanticRecorder()
        var actions: [WarrenDesktopAction] = []
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: projection.groups,
            workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
            workspaceDisplayMode: .rich,
            tree: .constant(WarrenDesktopSidebarTreeState()),
            selection: .workspace(workspace.id),
            selectedTabID: "tab.codex",
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onAction: { actions.append($0) },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        .frame(width: 420, height: 500)
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)

        let hostingView = NSHostingView(rootView: rows)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let richNodes = recorder.snapshot().nodes.filter {
            $0.id.hasPrefix("workspace-session.project-list.")
        }
        XCTAssertEqual(richNodes.count, 4)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: richNodes.map { ($0.label, $0.value) }),
            [
                // The open Session is the selected row, so its value carries the
                // selection the same way every other navigation row does.
                "Codex Session Implement API": "Working · API · feature · Selected",
                "Claude Code Session Review API": "Done · API · feature",
                "Shell Session Bound shell": "Working · API · feature",
                "Shell Session Plain shell": "API · feature",
            ]
        )
        XCTAssertTrue(
            richNodes.first { $0.label.contains("Implement API") }?.isSelected == true
        )
        XCTAssertFalse(richNodes.contains { $0.label.contains("Ended") })

        try recorder.perform(
            .press,
            on: "workspace-session.project-list.\(workspace.id.description).\(codex.id.description)"
        )
        XCTAssertEqual(actions, [.openSession(codex.id)])
    }
    @MainActor
    func testSelectingASessionLeafMovesTheHighlightOffItsWorkspace() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            name: "feature",
            path: "/tmp/api-feature"
        )
        // A second worktree, so the project draws its worktree rows rather than
        // holding the only one's Sessions directly.
        let other = Workspace(
            projectID: project.id,
            name: "main",
            path: "/tmp/api"
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            tabID: "tab.codex",
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            projects: [project],
            workspaces: [workspace, other],
            sessions: [session]
        )

        func nodes(selectedTabID: String?) throws -> [String: WarrenSemanticNode] {
            let recorder = WarrenSemanticRecorder()
            let rows = WarrenDesktopSidebarRows(
                taskGroups: [],
                groups: projection.groups,
                workspaceActivitySummaries: projection.workspaceActivitySummaries,
                activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                workspaceDisplayMode: .rich,
                tree: .constant(WarrenDesktopSidebarTreeState()),
                selection: .workspace(workspace.id),
                selectedTabID: selectedTabID,
                deletingProjectIDs: [],
                deletingWorkspaceIDs: [],
                endpointCapabilities: .local,
                isInteractionDisabled: false,
                onAddProject: {},
                onRequestTaskCreate: {},
                onFocusTask: { _ in },
                onAction: { _ in },
                onRequestRename: { _ in },
                onRequestDeletion: { _ in }
            )
            .frame(width: 420, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return Dictionary(
                recorder.snapshot().nodes.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let workspaceID = "workspace.project-list.\(workspace.id.description)"
        let leafID = "workspace-session.project-list."
            + "\(workspace.id.description).\(session.id.description)"

        let withLeafOpen = try nodes(selectedTabID: "tab.codex")
        XCTAssertEqual(withLeafOpen[leafID]?.isSelected, true)
        XCTAssertEqual(withLeafOpen[workspaceID]?.isSelected, false)
        XCTAssertEqual(
            withLeafOpen[workspaceID]?.value,
            "Contains the selected session · Not selected"
        )

        // With no Session open the workspace is the deepest live row, so it
        // takes the selection back rather than leaving the rail unanswered.
        let withNoLeafOpen = try nodes(selectedTabID: nil)
        XCTAssertEqual(withNoLeafOpen[leafID]?.isSelected, false)
        XCTAssertEqual(withNoLeafOpen[workspaceID]?.isSelected, true)
    }
    /// The tab strip no longer lists a workspace's other Sessions, so the leaf
    /// is the only place a Session can be renamed, pinned, or ended. A leaf
    /// without those actions would strand them.
    func testSessionLeafOwnsEveryPerSessionAction() {
        let titles = WarrenDesktopWorkspaceSessionRow.contextMenuActions(
            isPinned: false,
            onTogglePin: {},
            onRename: {},
            onEnd: {}
        ).compactMap { action -> String? in
            guard case .button(let title, _, _, _) = action else { return nil }
            return title
        }
        XCTAssertEqual(titles, ["Pin Session", "Rename Session", "End Session…"])

        XCTAssertTrue(
            WarrenDesktopWorkspaceSessionRow.contextMenuActions(
                isPinned: false,
                onTogglePin: nil,
                onRename: nil,
                onEnd: nil
            ).isEmpty,
            "A background Host's leaf stays navigable but offers no mutations"
        )

        let pinned = WarrenDesktopWorkspaceSessionRow.contextMenuActions(
            isPinned: true,
            onTogglePin: {},
            onRename: nil,
            onEnd: nil
        )
        guard case .button(let pinTitle, _, _, _) = pinned.first else {
            return XCTFail("Expected a pin action")
        }
        XCTAssertEqual(pinTitle, "Unpin Session")

        // With activity to retire, the leaf offers what the Tab offers, in
        // the Tab's order.
        let withActivity = WarrenDesktopWorkspaceSessionRow.contextMenuActions(
            isPinned: false,
            onTogglePin: {},
            onRename: {},
            onEnd: {},
            hasActivity: true,
            onDismissActivity: {}
        ).compactMap { action -> String? in
            guard case .button(let title, _, _, _) = action else { return nil }
            return title
        }
        XCTAssertEqual(
            withActivity,
            ["Pin Session", "Dismiss Activity", "Rename Session", "End Session…"]
        )
    }
    /// A Task-linked workspace appears twice in the tree, but only one copy owns
    /// navigation: the Task copy. Leaves follow navigability, so the Projects
    /// copy lists none and the Task copy lists them.
    ///
    /// With the Task collapsed the Task copy is not mounted at all, so those
    /// Sessions leave the tree the same way collapsing Projects hides the ones
    /// that copy owns.
    @MainActor
    func testRichSessionRowsFollowTheNavigableWorkspaceCopy() throws {
        let host = WarrenDomain.Host(name: "Agent Host")
        let task = WarrenTask(hostID: host.id, name: "Delivery")
        let project = Project(hostID: host.id, name: "API", rootPath: "/tmp/api")
        let workspace = Workspace(
            projectID: project.id,
            taskID: task.id,
            name: "delivery-api",
            path: "/tmp/api-delivery"
        )
        let session = WarrenDesktopSession(
            id: TerminalSessionID(),
            workspaceID: workspace.id,
            title: "Implement API",
            kind: .codex,
            activity: .working
        )
        let projection = WarrenDesktopProjection(
            host: host,
            tasks: [task],
            projects: [project],
            workspaces: [workspace],
            sessions: [session]
        )

        for isTaskFolded in [true, false] {
            let recorder = WarrenSemanticRecorder()
            let rows = WarrenDesktopSidebarRows(
                taskGroups: projection.taskGroups,
                groups: projection.groups,
                workspaceActivitySummaries: projection.workspaceActivitySummaries,
            activeSessionsByWorkspaceID: projection.activeSessionsByWorkspaceID,
                workspaceDisplayMode: .rich,
                tree: .constant(WarrenDesktopSidebarTreeState(
                    selectedTab: .tasks,
                    collapsedTaskIDs: isTaskFolded ? [task.id] : []
                )),
                selection: nil,
                deletingProjectIDs: [],
                deletingWorkspaceIDs: [],
                endpointCapabilities: .local,
                isInteractionDisabled: false,
                onAddProject: {},
                onRequestTaskCreate: {},
                onFocusTask: { _ in },
                onAction: { _ in },
                onRequestRename: { _ in },
                onRequestDeletion: { _ in }
            )
            .frame(width: 420, height: 500)
            .warrenSemanticObservationRoot(recorder: recorder)
            .environment(\.warrenSemanticRecorder, recorder)

            let hostingView = NSHostingView(rootView: rows)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))

            let sessionIDs = recorder.snapshot().nodes
                .filter { $0.id.hasPrefix("workspace-session.") }
                .map(\.id)
            let expected: [String] = isTaskFolded
                ? []
                : [
                    "workspace-session.task-list.\(workspace.id.description)"
                        + ".\(session.id.description)",
                ]
            XCTAssertEqual(
                sessionIDs,
                expected,
                "Task expansion \(isTaskFolded ? "collapsed" : "expanded")"
            )

            // The Task lists the Workspace; Projects does not draw it again.
            let snapshot = recorder.snapshot()
            XCTAssertNil(
                snapshot.node(id: "workspace.project-list.\(workspace.id.description)"),
                "The Projects section does not repeat a Task's Workspace"
            )
            if !isTaskFolded {
                XCTAssertTrue(
                    snapshot.node(id: "workspace.task-list.\(workspace.id.description)")?
                        .isEnabled ?? false,
                    "The Task copy owns navigation and therefore the leaves"
                )
            }
        }
    }
}
