# Warren UI Presentation Unification Plan

Status: Draft — implementation is blocked until this specification is approved.

Branch: `refactor/ui-presentation-unification`

Scope: Warren macOS Desktop, Web/PWA, and the shared DesignSystem. Onboarding is
not a functional presentation surface today and remains out of scope unless a
later review adds an explicit requirement.

## 1. Problem statement

Warren currently has four presentation stacks:

1. macOS system presentation (`sheet`, `alert`, `popover`, `NSMenu`,
   `NSOpenPanel`, and `NSAlert`);
2. macOS in-window Warren presentation (`WarrenModalBackdrop`,
   `WarrenPanelSurface`, and the dialog/input primitives);
3. Web React/CSS presentation (dialogs, sheets, menus, drawers, and panes);
4. browser-native presentation (`window.prompt`, `window.confirm`, and native
   `<select>`).

The same resource action therefore has different visual and interaction
contracts on different clients. The largest examples are rename, deletion,
import, and error reporting. `DESIGN.md` describes a unified vocabulary, but
several current code paths still use native sheets, native alerts, rounded
border fields, or browser prompts.

This plan unifies the semantic contract first and then migrates each existing
surface one by one. It does not change domain ownership, command semantics, or
the terminal renderer.

## 2. Design goals and non-goals

### Goals

- One semantic presentation taxonomy shared by macOS and Web.
- One set of surface, spacing, radius, elevation, motion, and focus roles.
- Equivalent presentation for shared actions, while preserving explicitly
  documented client boundaries.
- Predictable keyboard, pointer, touch, accessibility, loading, error, empty,
  and retry behavior.
- A single owner for modal state and z-order in each client.
- A clean boundary between app-owned surfaces and OS-owned panels.
- A migration that can be reviewed and reverted one primitive at a time.

### Non-goals

- Replacing the terminal theme or Ghostty rendering behavior.
- Styling external IDEs, Finder, browser windows, or macOS global menus beyond
  what the platform allows.
- Introducing a second application window for settings or dialogs.
- Changing the Host protocol, persistence model, or resource lifecycle rules.
- Rebuilding the entire Web component hierarchy in one change.

## 3. Normative presentation taxonomy

Every new or migrated surface MUST choose exactly one role below. A component
MUST NOT select a role because of its current implementation primitive (for
example, a sheet is not automatically a `Sheet` role).

| Role | Use | Blocking | Backdrop | Dismissal | Canonical size |
| --- | --- | --- | --- | --- | --- |
| `Modal` | Business input, confirmation, or an error requiring a decision | Yes | 50% scrim | Explicit Cancel, Escape; backdrop click does not dismiss | Compact 400px, standard 480px |
| `Sheet` | Multi-row selection or a short action list that benefits from a larger working area | Yes while open | 50% scrim on mobile; desktop may use the same scrim | Cancel/Escape; backdrop click only when no uncommitted input exists | Wide 720px desktop; full width mobile |
| `CommandSurface` | Keyboard-first command/search palette | Yes for keyboard focus, not for data safety | 50% scrim | Escape, backdrop click | Max 720px, max 80% viewport height |
| `Popover` | Local status or selection anchored to a control | No | None | Outside click, Escape, selection | Content-sized, max 320px |
| `Menu` | Short command list, including context actions | No | None on desktop; mobile action-sheet presentation may use a soft scrim | Outside click, Escape, selection | Content-sized; 44px touch rows |
| `Pane` | Persistent contextual information such as Inspector or Git | No | None | Explicit close/toggle | 340px default, resizable where already supported |
| `Status` | Non-blocking progress, success, warning, or connection feedback | No | None unless the operation is explicitly blocking | Automatic or explicit action | Content-sized |
| `OSPanel` | Folder/app selection or another OS-owned workflow | Platform-defined | Platform-defined | Platform-defined | Platform-defined |
| `Window` | Application-level host window only | N/A | N/A | Platform-defined | One Warren main window |

### Required role decisions for current surfaces

- Rename, delete, terminal-group editing, workspace creation, IDE errors, and
  CLI result messages use `Modal`.
- Superset import and existing-worktree import use `Sheet` on desktop and a
  bottom `Sheet` on mobile. They are app-owned surfaces, not native SwiftUI
  sheets.
- Endpoint selection is a `Popover`; the External IDE action list is a
  `Menu`.
- Command Palette remains a `CommandSurface`, not a generic modal.
- Inspector and Git are `Pane` surfaces.
- Connection, maintenance, and copy feedback use `Status`.
- Folder and application selection remain `OSPanel` (`fileImporter` or
  `NSOpenPanel`) because Warren does not own those workflows.

## 4. Visual contract

The macOS DesignSystem remains the semantic source of truth. Web CSS variables
mirror the same roles and components MUST reference semantic variables rather
than raw values.

### 4.1 Color roles

Use the existing Ember roles from `WarrenColorTokens` and `Web/src/style.css`:

- page: `#151110`;
- chrome/sidebar: `#1c1918`;
- raised/popup surface: `#201e1c`;
- input/sunken surface: `#181615`;
- primary text: `#eae8e6`;
- secondary text: `#a8a5a3`;
- border/separator: `#2a2827` / `#3a3837`;
- accent/focus: `#e07850`;
- destructive: `#cc4444` (macOS) / the equivalent semantic danger role on Web;
- working/warning/success/info roles remain the documented Ember values.

No component may introduce a new hard-coded surface or status color without a
DesignSystem change and a review note.

### 4.2 Radius roles

Add explicit semantic names so a component does not choose an arbitrary radius:

- `row/control`: 6px;
- `popover`: 10px;
- `dialog`: 12px;
- `sheet`: 16px on mobile top corners, 12px for the desktop sheet surface;
- `pill`: 999px.

The existing `WarrenRadius` values remain the implementation source; the Web
radius variables must be mapped to the same names. A one-off radius is a
design exception, not a local tweak.

### 4.3 Elevation roles

Replace the current “one shadow for every macOS panel” behavior with named
roles mirrored in Web:

- `popover`: hairline border plus a restrained 12/40 shadow;
- `dialog`: hairline border plus the stronger 24/70 shadow;
- `sheet`: top-oriented 14/50 shadow;
- `inline`: no elevation; use a separator or translucent wash.

The role is applied by the presentation primitive, not by individual screens.

### 4.4 Geometry and spacing

Use the existing `WarrenSpacing` scale and these presentation widths:

- compact dialog: 400px;
- standard dialog: 480px;
- wide command/import surface: 720px maximum;
- popover: 220–320px unless content requires less;
- persistent pane: 340px default, respecting existing min/max constraints.

Desktop surfaces must have a maximum height and an internal scroll region.
Mobile surfaces must respect safe-area insets and use at least 44px touch rows.

### 4.5 Motion

- Mount/unmount transitions use the shared overlay duration (150–200ms).
- Popovers and menus may use a short opacity/scale transition.
- Sheets use a vertical slide only on mobile.
- `prefers-reduced-motion` and `accessibilityReduceMotion` disable movement,
  retaining a state change through opacity or immediate placement.

## 5. Interaction and accessibility contract

Every app-owned presentation primitive MUST provide:

- a stable accessibility identifier, role, label, value, and enabled state;
- initial focus on the first meaningful control;
- focus restoration to the invoking control after dismissal;
- Escape handling that dismisses only the topmost dismissible surface;
- Return/Command-Return behavior for the primary action where appropriate;
- a visible focus ring using the accent role;
- a loading state that prevents duplicate submission;
- an error state with a recoverable action or explicit retry guidance;
- an empty state explaining why there is nothing to select;
- disabled/destructive states that explain the consequence.

Additional rules:

- `Modal`: trap focus while open; backdrop click never silently discards input.
- `Sheet`: trap focus while open; backdrop click is allowed only before a
  mutation or when the sheet has no editable state.
- `CommandSurface`: focus the query field and support arrow/Home/End navigation.
- `Popover` and `Menu`: close on outside pointer down and Escape; arrow-key
  navigation is required for menus.
- `Pane`: remains in the accessibility tree when visible and has an explicit
  close/toggle action.
- Mobile menu presentation MUST expose `role="dialog"`/`aria-modal="true"`
  when it visually behaves as a blocking bottom sheet; it must not retain a
  misleading menu role.

## 6. Platform policy

### macOS

- Use app-owned in-window primitives for business dialogs and import flows.
- Keep `fileImporter` and `NSOpenPanel` for OS-owned file/app selection.
- Keep native AppKit global menus and native context menus for platform
  conventions, but make their action labels and ordering match Web.
- Do not introduce `WindowGroup` or additional Warren-owned windows for these
  surfaces.
- Route native-menu actions that need an app-owned result back into the root
  presentation coordinator instead of calling `NSAlert` directly.

### Web/PWA

- Replace `window.prompt` and `window.confirm` with the shared React modal
  primitive.
- Keep the native `<select>` only if its semantics are required; otherwise
  wrap it in the shared control styling without changing keyboard behavior.
- Use one context-menu component with a desktop popover adapter and a mobile
  action-sheet adapter, sharing the same semantic role and action model.
- Keep Settings as a page-level replacement, not a modal or a new browser
  window.
- Preserve `target="_blank"` for external PR/IDE navigation because those
  windows are outside Warren's ownership.

## 7. Shared component boundaries

### macOS DesignSystem additions

Introduce small, composable primitives rather than screen-specific wrappers:

- `WarrenPresentationRole` and named surface metrics;
- `WarrenPresentationCoordinator` (one topmost surface and focus owner);
- `WarrenModalSurface`;
- `WarrenSheetSurface`;
- `WarrenPopoverSurface`;
- `WarrenMenuSurface` only for app-owned menu content that cannot use native
  `Menu`;
- `WarrenStatusSurface`;
- role-specific panel modifiers (`popover`, `dialog`, `sheet`, `inline`).

Existing `WarrenTextInputDialog`, `WarrenInputField`, and button styles should
be adapted to these boundaries instead of duplicated.

### Web boundaries

Introduce a small presentation layer in `Web/src`:

- `Modal`; `Sheet`; `CommandSurface`; `Popover`; `ContextMenu`; `StatusSurface`;
- a single `usePresentationStack`/controller for topmost dismissal and focus;
- semantic CSS variables for role, elevation, and z-order;
- no component-specific z-index literals.

The macOS and Web implementations may differ internally, but their action
payloads, labels, dismissal rules, and semantic states must match.

## 8. Z-order contract

Use one semantic layer map in both clients:

```text
content             0
inline overlay     10
drawer             20
popover/menu       30
command surface    40
modal/sheet        50
context menu       60
OS-owned panel     platform-managed
```

Only the presentation coordinator may choose a layer. A local view must not
add an arbitrary z-index to resolve an ordering bug; it must declare its role.
Mutually exclusive top-level surfaces (for example, Settings and Command
Palette) must close one another before mounting.

## 9. Migration plan

Each phase is an independently reviewable change. Do not mix unrelated backend
or generated `Web/dist` changes into these commits.

### Phase 0 — Contract and token foundation

- [ ] Add this approved taxonomy and role metrics to the DesignSystem.
- [ ] Add role-specific elevation, sheet radius, and z-order tokens.
- [ ] Mirror the semantic tokens in `Web/src/style.css`.
- [ ] Add the macOS presentation coordinator and Web presentation stack.
- [ ] Add semantic tests for focus, Escape, outside click, and topmost-layer
      dismissal.

### Phase 1 — Business modals and system feedback (P0)

- [ ] Migrate macOS Superset import preview from native `.sheet` to
      `WarrenSheetSurface`.
- [ ] Migrate macOS Workspace creation from native `.sheet` to the shared
      modal/sheet primitive.
- [ ] Migrate macOS existing-worktree import from native `.sheet` to the shared
      sheet primitive.
- [ ] Replace the Terminal Group editor's `.roundedBorder` fields with
      `WarrenInputField`.
- [ ] Replace macOS IDE failure `Alert` and CLI `NSAlert` result flows with the
      app-owned modal/status contract.
- [ ] Replace Web rename `window.prompt` calls with the shared modal.
- [ ] Replace Web session deletion `window.confirm` with the shared destructive
      modal.
- [ ] Preserve the current Web product boundary: do not add Project/Workspace
      deletion in this UI migration. Only the existing Web Session deletion
      flow is migrated to the shared destructive modal.

### Phase 2 — Popovers, menus, and selectors

- [ ] Apply the popover role surface to Endpoint selection.
- [ ] Align External IDE menu labels, order, disabled states, and keyboard
      behavior with Web.
- [ ] Consolidate the seven macOS context-menu sites behind one action model.
- [ ] Consolidate Web Project/Workspace/Tab/Session context actions behind the
      same action model.
- [ ] Give the Web mobile context menu dialog semantics when rendered as a
      bottom sheet, including scrim, focus, and safe-area handling.
- [ ] Normalize the Git branch selector styling without removing native select
      keyboard/accessibility behavior unless a replacement is proven equivalent.

### Phase 3 — Command, transient, and persistent surfaces

- [ ] Move macOS Command Palette to the shared command-surface role and layer.
- [ ] Move the macOS Web panel and terminal search to role-specific popover
      surfaces.
- [ ] Normalize Superset loading, terminal connection, maintenance, and copy
      feedback as `Status` surfaces.
- [ ] Normalize the Web terminal search, Git loading, and file-diff overlays.
- [ ] Normalize the mobile drawer/backdrop against the soft-scrim contract.
- [ ] Align Inspector and Git pane width, header, close action, and focus rules.
- [ ] Keep Settings as an in-window page replacement on both clients, with the
      same back/Escape behavior.

### Phase 4 — Documentation, generated assets, and hardening

- [ ] Update `DESIGN.md` to describe the implemented contract rather than the
      intended one.
- [ ] Add a presentation inventory test/lint that rejects new browser prompts,
      unapproved native business alerts, raw Web elevation values, and local
      z-index literals.
- [ ] Run macOS semantic UI tests and Web keyboard/accessibility tests for every
      role and state.
- [ ] Verify fresh-checkout build/run behavior and generated asset handling.
- [ ] Record the review-standard risks and mitigations before requesting merge.

## 10. Acceptance matrix

Every migrated surface must be checked in these states:

- closed/open;
- initial focus and focus restoration;
- keyboard navigation and Escape;
- pointer outside click and touch outside click;
- loading, success, error, empty, retry, and disabled;
- destructive confirmation and duplicate-submit prevention;
- desktop, narrow desktop, mobile, and safe-area layout;
- reduced motion;
- VoiceOver/Accessibility tree or Web ARIA tree;
- no unexpected change to the active Workspace/Session or terminal focus.

The acceptance evidence should use the semantic observation artifacts already
defined in `DESIGN.md` rather than screenshots alone.

## 11. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Replacing native sheets changes focus or resize behavior | Preserve explicit focus/size tests and migrate one flow at a time |
| Web modal migration changes browser history or refresh behavior | Keep presentation state local to the existing controller; do not encode it in the URL |
| Feature parity work expands into domain changes | Reuse existing typed commands and stop at the presentation boundary |
| Native menus cannot share every visual detail | Share semantic action models and labels; keep platform-native rendering where required |
| Large dirty working tree obscures review | Work only in the Warren-managed workspace and keep commits scoped to presentation files |
| Generated Web assets create noisy diffs | Build/generated output is a separate explicit step and must not be mixed with source commits |

## 12. Decision record

The following decisions were confirmed for this plan:

1. Business dialogs and import flows become app-owned in-window surfaces.
   Native `.sheet` remains only for OS-owned workflows such as folder or
   application selection.
2. Mobile bottom sheets use 16px top corners, safe-area insets, and 44px touch
   rows.
3. Modal backdrop clicks do not dismiss editable or destructive dialogs.
4. Web Project/Workspace deletion is explicitly out of scope. This migration
   must not add those actions; it only replaces the existing Web Session
   confirmation UI.
5. macOS global and context menus remain native where platform conventions
   require. “Mirror semantics” means the clients share action IDs, labels,
   ordering, enabled/destructive states, and keyboard intent; it does not mean
   forcing native macOS menus and Web menus to look pixel-identical.
6. Onboarding is explicitly out of scope.

Implementation proceeds in the phase order above inside the
`refactor/ui-presentation-unification` workspace after final approval. Each
phase gets a typed commit prefix (`refactor:`, `fix:`, `test:`, or `docs:`) and
its own checks.
