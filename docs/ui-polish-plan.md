# UI polish plan (branch `refactor/ui-constraints`)

Status: living document. Update the checklist as work lands. It exists because
this pass is long enough to outlive one context window; a requirement written
only in a chat message is a requirement that gets forgotten.

Requirements as given by the user (2026-11-06), in their order:

- **R1 Dialog confirm must never wrap.** A dialog's confirm label is one line,
  always. "Delete Workspace" is too long for a small dialog: the action is
  **"Delete"** — the title already says what is being deleted.
- **R2 One design for every overlay.** Hover popovers and *all* context menus
  (right-click) must read as the same family as the menus, palette and dialogs
  that were already unified. Audit them, then fix what disagrees.
- **R3 Taste skill for unification, not for rebuilding.** Use
  `design-taste-frontend` to judge spacing, type and composition. Do not
  replace the foundation — the derived palette, the grid, the row anatomy stay.
  **Settings is the one exception**: it may take a new foundation if the skill's
  read says the current one is not good enough.
- **R4 Split-pane icons overlap too much.** When two Sessions share one pane,
  the top bar stacks their icons; the overlap is too deep. Reduce it.
- **R5 Settings.** Same treatment as everything else: audit, unify, tune.
- **R6 This document.** Keep it current so a compacted context can resume.

Definition of done for each item: the change is visible in `UIShot` (or in a
real-app screenshot where the surface cannot be rendered offscreen), the
relevant tests pass, and the commit message says what the user sees differently.

## Checklist

### R1 — dialogs
- [x] Confirm label never wraps: the button styles carry `lineLimit(1)` +
      `fixedSize`, and the footer no longer draws a second label beside them.
- [x] Destructive confirmations say "Delete". The app's call sites already did;
      the wrapping one was the gallery's sample label, now fixed. Rule recorded
      in the gallery: the title names the object, the button names the verb.
- [x] Every call site checked: Delete, Rename, Create, Import, Save, Rebuild,
      Reset, Rotate, Revoke — all one short verb.

### R2 — overlays and context menus
- [x] Inventory: SwiftUI menu surface, command palette, hover cards
      (`isPassive` panels), context menus, tooltips, toasts, detail card, chrome
      popover, host picker, approval tray, folded rail.
- [x] Context menus are **not** `NSMenu`: `WarrenDesktopMenuCenter` draws them
      in-window, so right-click menus, menu-button drop-downs and hover cards
      are literally the same surface and row code as the menus.
- [x] All of them now read the derived palette: `WarrenDesktopMenuPalette` is
      computed from `WarrenColorTokens` instead of carrying 26 literals, so a
      menu, a popover and a toast share one tone, border, wash and danger
      colour. Chrome popover and toasts already used the shared card modifier;
      tooltip and detail card resolve `popoverSurface`.
- [ ] Remaining taste deviation, accepted: floating surfaces carry a hairline
      *and* a shadow, which the skill's card rule discourages. On a near-black
      ground the hairline is what makes the edge legible; removing it would
      trade a rule violation for a mushy edge. Keep, and note here.

### R3 — taste pass
- [ ] Read the skill's house rules and extract the ones that apply to native UI
      (spacing rhythm, type scale, one accent, no decorative gradients, quiet
      borders, alignment to a single grid).
- [ ] Apply them to the surfaces in scope; log each deviation found.

### R4 — split-pane icon stack
- [x] The stack is the group pill's fan; the rest pitch was 5 for a 16pt mark.
- [x] Raised to 10: each mark now shows most of itself (the third member used to
      vanish), while the stack still measures narrower than its members in a
      row. Lifted pitch (22) unchanged, so the lift still separates them fully.
- [x] `UIShot --surface fan` renders the pill with three members at rest, which
      is otherwise impossible to photograph without owning a group.

### R5 — settings
- [x] Foundation kept: opaque group boxes, one card per group. It is coherent,
      already derives its palette from the tokens, and rebuilding 5.3k lines of
      page structure is not what "unification and tuning" means.
- [x] Tuning applied: row title 13 → 14 (`settingsBody`), description and group
      footnote 11.5 → 12 (`settingsMeta`), row title/description gap 2 → 3. At
      13/11.5 the pair read as one run of text with a line break in it.
- [x] Settings is now renderable offscreen: `UIShot --surface settings
      --section <Name>` builds the real page with a fixture (values for the
      ~35 Host parameters, no live Host).
- [x] Disabled actions no longer look like the button to press: `primary` and
      `destructive` now draw as a quiet outlined control (field surface, hairline,
      supporting ink) instead of the old 0.42-opacity plate. This is where a dead
      red "Rotate Code…" came from, and it applies to every dialog and form.
- [x] Access page: the second "Connection" group is now "Relay connection" — two
      identical group headings on one page name nothing.
- [x] Density measured against Superset's settings (`apps/desktop/.../settings`,
      pulled 2026-11-08): page header `mb-8`, sections `space-y-6`, card
      `rounded-lg border divide-y`, rows `p-4` with `text-sm font-medium` over
      `text-xs text-muted-foreground`, content `max-w-4xl/5xl`. Warren's rows
      were 14/10 with a 44pt floor and a 640 column, which is what read tight.
- [x] Applied: row padding 16/14 with a 56pt floor, row title 14 medium,
      section header 16/12, page header gap 32, column 640 → 800, paragraphs
      (footnotes and page notes) capped at a 560 reading measure.
- [x] Width: the column was 800 and left-aligned, which left a wide empty
      strip on the right of every page. It is now 1040 (Superset's `max-w-5xl`)
      for forms and 1240 for Usage, centred in the space beside the navigation —
      at 1040 the column nearly fills the panel, so centring only bites on a
      very wide window, where it is what keeps one gutter instead of two. Row
      descriptions widen from 420 to 520 so a wider card is not a wider blank.
      Checked at 1440 and 1800, dark and light: Appearance, Access, Usage,
      Workspaces, Launch Commands, Terminal.
- [ ] Open: `Usage` and `Workspaces` reviewed only at their empty state (the
      fixture has no usage data yet).

## Rules of engagement (from AGENTS.md)
- Keep changes focused; no scope creep beyond the list above.
- Verify on the running artifact for surfaces that cannot be rendered offscreen.
- Promptly commit with an English, typed message; keep this branch to one
  squashed commit unless the user says otherwise.

## Taste read (R3), applied rules
From `design-taste-frontend` → `references/app-screens.md`, the rules this pass
used, and where each was applied:
- Colour on data, not chrome → the accent stays on identity/brand marks; chrome
  reads neutrals from the derived palette.
- Surfaces flat; separation by a line or one tone step → cards keep a hairline,
  floating surfaces carry the shadow.
- No blank band inside a card → dialog body inset closed for content-less
  dialogs; palette ends where its results end.
- Rows end on one edge → row anatomy's trailing slots.
- Settings: label then answer, description quiet → the R5 type change.
- Nothing under 11px for text → **not applied wholesale**; the app uses 9-10.5pt
  for badges and key glyphs by design. Note as a known deviation.
- Icons in tinted squares → kept for project avatars and program marks: they
  are identity and brand, not decorative KPI icons.

## Acceptance inventory (every surface, and how it was checked)

Rendered offscreen with `UIShot` unless noted. "Looked at" means the PNG was
opened and judged, not merely produced.

| Surface | How | State |
| --- | --- | --- |
| Window, dark | `--surface root` | looked at; sidebar, tab pill, pane card, gutters |
| Window, light | `--surface root --appearance light` | looked at |
| Window, hover state | `--surface root --hover` | looked at; `+` and fold chevrons on one column |
| Dialog family (rename, destructive confirm, form) | `--surface dialog` | looked at; no wrap, no void, keycap |
| Command palette | `--surface palette` | looked at; ends where results end |
| Split group pill, 3 members | `--surface fan` | looked at; rest pitch 10 |
| Settings · Appearance | `--surface settings --section Appearance`, dark + light | looked at, both appearances |
| Settings · Terminal | `--section Terminal` | looked at; preview card and token chips |
| Settings · Splits | `--section Splits` | looked at; shortcut column |
| Settings · Launch Commands | `--section "Launch Commands"` | looked at; segmented control, preset rows, disabled row legible |
| Settings · Editors | `--section Editors` | looked at |
| Settings · Notifications | `--section Notifications` | looked at |
| Settings · Workspaces | `--section Workspaces` | looked at; reference table denser than form rows |
| Settings · Terminal Runtime | `--section "Terminal Runtime"` | looked at |
| Settings · AI Titles | `--section "AI Titles"` | looked at; first card now has a heading |
| Settings · Usage | `--section Usage` | looked at at its empty/loading state only |
| Settings · Access | `--section Access` | looked at; groups, quiet disabled actions |

Not verifiable offscreen, and therefore **not** claimed as verified:
- the terminal surface itself (Ghostty/Metal is not in the offscreen host);
- a context menu or hover popover anchored over a live row (the menu code is
  shared and was read, but the anchored placement was not photographed);
- toasts and tooltips (transient, need a live window);
- Settings inside the running app (the page needs a live Host; the offscreen
  fixture covers layout and both appearances, not the live data).

Say so at acceptance rather than implying a full sweep.

## Settings window chrome (found at acceptance)
The page was drawn in a standard titled `NSWindow`: a system titlebar, a square
frame and the system's grey above Warren's backdrop. Offscreen it looked right,
because a render has no titlebar. It now runs `.fullSizeContentView` with a
transparent, title-hidden titlebar, a clear window background and an 8-point
clipped corner on the hosting view, so the page paints one seamless surface
under the traffic lights. The page adds no top gutter of its own: the hosting
view's top safe area already reserves the lights' row, and adding one put the
first card 53 points down. Verified by opening it in the running app
(`warren://settings/appearance`) and photographing the window.

## Landmines found
- Adding a conditional child (`if remoteAccess.enabled { Button … }`) inside the
  Share row's `HStack` segfaults SwiftUI's offscreen layout in `NSHostingView`.
  The change was reverted. Any restructuring of that row needs a real-app check,
  not just the gallery.

## Progress log

- 2026-11-06: plan written.
- 2026-11-08: R1 closed, R4 closed (rest pitch 5 → 10, verified in the gallery),
  R2 audited and closed except the accepted border+shadow note, R3 applied and
  logged, R5 renderable and tuned; Settings disabled-action styling fixed in the
  design system. Preceding work on this branch (derived palette, grid
  test, row anatomy, overlay palette, keycaps, dialog pass, palette sizing) is
  in commit `b63847c87`.
