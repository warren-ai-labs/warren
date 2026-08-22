# RFC 0005: Resource links and the desktop notice center

- Status: Complete
- Owner: Warren Desktop and Web clients
- Created: 2026-08-22
- Scope: navigation links, transient system messages, and text-input ergonomics

## Goal

Make Warren's resource links stable enough for launchers and copied URLs while
keeping the desktop terminal geometry fixed when messages are shown. The same
navigation model must understand Project, Workspace, and Session targets by
either UUID or current display name. A renamed resource intentionally makes an
old name-based link unresolved; the client must report that failure instead of
silently opening a different resource.

## Delivery steps

1. **Resource-link contract**
   - Extend `warren://terminal` with `project`, `workspace`, and `session`
     selectors.
   - Accept selectors as UUIDs or current names, retain the legacy `group`
     selector, and resolve names only within their requested parent scope.
   - Extend the Web hash state with the optional project level and resolve all
     three levels before changing the active terminal.
2. **Notice center**
   - Replace desktop error diagnostics and one-shot message dialogs with
     bounded notices owned by the application model.
   - Add a bell control to the existing top chrome. Opening it shows a compact
     floating popover; selecting an item switches to its detail view without
     changing terminal width or height.
   - Route diagnostics, system messages, and update failures through this
     center. Keep a bounded in-memory history and preserve unread state until
     an item is opened.
3. **Remove the right diagnostic sidebar**
   - Stop rendering the right diagnostic slot and its toggle control. Remove
     the retired projection fields and actions so the layout has no hidden
     width reservation or alternate error path.
4. **Unix text editing**
   - Apply common Unix editing chords to every Web text input (without
     intercepting the terminal's own PTY textarea).
   - Add the same control-key behavior to native AppKit text fields through a
     shared field-editor command bridge.
5. **Verification**
   - Add focused parser, resolver, notice, and keyboard tests.
   - Run `npm --prefix Web run check`, relevant Swift package tests, and the
     repository verification task when the local toolchain permits it.
   - Review business, interaction, performance, fresh-checkout, and coupling
     risks before committing.

## Implementation record

- Native deep links now resolve project, workspace, and session selectors by
  UUID or current name, with exact parent scoping and fail-closed stale names.
- Web hashes carry `p=`, `w=`, and `s=` selectors and use the same fail-closed
  resolver before attaching a terminal.
- Desktop notices are bounded to 50 entries, preserve unread state, and show
  list/detail views in an overlay anchored to the top chrome.
- AppKit field editors and Web inputs share the Unix editing chords while the
  terminal helper textarea remains untouched.
- Workspace chrome now keeps one-level actions in a stronger `More` menu. The
  menu uses regular labels with light metadata, direct actions only, and a
  dedicated menu elevation so it reads as an intentional action surface.
- Top-bar controls are data-driven: callers may promote selected controls to
  the direct chrome, with a hard maximum of five visible buttons. The overflow
  affordance reserves one slot whenever hidden controls remain; the original
  IDE, Web, and notification controls remain direct by default while endpoint
  switching and Settings are available from More.

## Acceptance criteria

- `warren://terminal?project=<selector>&workspace=<selector>&session=<selector>`
  can target any existing Project/Workspace/Session; omitted levels use the
  remembered/default child.
- Existing `warren://terminal?group=<name-or-uuid>` links still work.
- A stale name link fails with an actionable notice and never falls back to a
  similarly named resource.
- Clicking the bell and opening notice details leaves terminal dimensions
  unchanged.
- No right-side diagnostic control or layout slot remains visible.
- Command/Control-A selects all, Control-A/Control-E move to line start/end,
  and the surrounding Unix editing chords work in every non-terminal input.
- Workspace actions beyond the direct-control set are reachable from the
  compact `More` menu; selecting a multi-step action replaces its list with an
  inline detail view and a back affordance, without dismissing the surface or
  resizing the terminal.
- Direct workspace controls never exceed five visible buttons, including the
  overflow affordance when it is present.

## Risk notes

- Name selectors are mutable and can become stale; resolution is exact and
  scoped, and ambiguity is treated as failure.
- Notices add bounded client memory only; terminal output and transport paths
  remain unchanged.
- Removing the diagnostic sidebar changes only diagnostic presentation, not
  Host state ownership or terminal layout. The retired right-side slot no
  longer exists.

## Verification results

- `swift test --package-path Packages/Desktop -Xswiftc -warnings-as-errors`
  — 95 tests passed.
- `swift test -Xswiftc -warnings-as-errors` — 45 tests passed.
- `npm --prefix Web run check` — 129 Node tests passed and the Vite build
  completed successfully.
- `git diff --check` — clean.
