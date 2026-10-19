# Seven design decisions — state

Temporary tracker for `seven-decisions`. Delete this file when the work lands.

## Delivered

| # | Item | What shipped |
|---|---|---|
| 1 | Top-bar title | `SessionTitle.resolve` for the top bar, sidebar row, pane header and tab; running command beside the title; 345pt cap with a 28pt tail fade; click menu (rename, copy command, copy path, open in editor); 450ms detail card |
| 2 | Second-line verbs | Shell rows name the command in the monospaced face with no verb, shortened by `CommandSummary`; a resting Agent row leads with the Host's result sentence and keeps its counts as the fallback |
| 3 | Idle shell collapse | 600s rest → one 30pt line; a failed command waits until the Session is looked at; the pointer over the rail postpones it; hover card carries the last command, code, directory, branch |
| 4 | `WarrenDialog` | One container with S/M/L widths, keycap buttons, top-anchored position; rename, message, three delete confirmations, Usage rebuild, New Task, New workspace, worktree import, Superset import and the setup-script editor all draw inside it |
| 5 | Permanent `+` | Projects and Tasks always show it left of the fold arrow |
| 6 | Selection motion | Plate slides on `WarrenMotion.selection` (tabs, settings nav, segmented); no outer tab capsule; 200/96 tab widths; `⌄ N` overflow list; tab titles fade; a tab more than a viewport away gets the plate without travel |
| 7 | Settings window | Separate ⌘, window (860×620, min 720×480, remembered); 220pt monochrome nav; 656pt reading column; 44pt rows; search results name their scope; Terminal ↔ Terminal Runtime cross-links; the palette derives every value from the shared tokens |
| 8 | Settings controls | Colour-card ring; terminal/template previews; merged Launch Commands with drag and ⌥↑/⌥↓ reorder; editor ✓ column; setup-script row + L dialog; `WarrenCodeChip`; AI Titles Save & Test form; Public Access status row; inline Relay invite and LAN PIN with countdown; Usage's own data palette |

Host work that came with it: the result sentence (title endpoint, stored on the
session, projected to clients) and a `relay.enabled` command.

## Open

- **Relay switch on the connection row.** The Host command (`relay.enabled`) and
  the client method exist; the Settings row has the switch and takes
  `onSetRelayEnabled`. Passing it from the app needs one more argument on
  `WarrenDesktopRoot`, which pushes the composition root's single expression
  past the type checker's budget — that file needs the root view and its
  observer chain split into separate expressions first.
- **Add SSH Host** stays the host picker's drill-in list rather than a dialog:
  it adds on tap and has no form fields, so the dialog spec's field sizes do not
  apply to it.
- **Shortcut recording** (item 8-C) is specified but not built, as the design
  says: shortcuts stay read-only.

## Notes

- Sanctioned deviation: the top-bar title cap is 345pt of title (≈420pt pill)
  rather than 360, because long Session names needed the room.
- Known pre-existing failure: `WarrenTests/WarrenDiffViewRenderTests.testVerticalWheelScrollsTheList`
  fails on this machine at older commits too (the wheel event is not delivered).
