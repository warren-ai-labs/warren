# 2026-08-28 minimum-contrast experiments for codex Working visibility

## Context
Warren's Ghostty embedding uses a dark theme `background #151110` / `foreground #eae8e6` (`GhosttySurface.swift:68`). Codex TUI emits pure-black truecolor `38;2;0;0;0` for its "Working" header and a shimmer gradient for the spinner. On `#151110` pure black has WCAG contrast `1.12`, invisible. Ghostty's `minimum-contrast` snaps low-contrast foreground to white/black in shaders.

## Attempts and observations

### 1. No setting (default 1)
- `TerminalConfiguration.swift:338` `default` has no `minimum-contrast`; Ghostty `Config.zig:780` defaults to `1`.
- Result: `0,0,0` stays pure black, invisible on `#151110`. Spinner greys stay as emitted.

### 2. 4.5 → pure white (reported)
- Commit history: `4.5` made `38;2;0;0;0` pure white `vec4(1.0)`, too harsh.

### 3. 2.5 → expected grey, observed white (local)
- Commit `ea52172` expected `2.5` → grey `#5c5856` (bright-black). Calculation `target = 2.5*(Lbg+0.05)-0.05` → luminance `0.089` → sRGB `85` ≈ `#555` close to `#5c5856` (92,88,86, contrast 2.67).
- Local test with `warren session read 65f402e3-6b63-44c8-8051-431cd22e7736` after `GhosttySurface.swift:84` `2.5` still produced pure white. Shader `ghostty/src/renderer/shaders/glsl/common.glsl:97` / `shaders.metal:111` `contrasted_color` is binary: `if(ratio<min) return white_ratio>black_ratio ? white : black`. For `#151110`, `white_ratio 18.7 > black 1.12`, so any `min>1.12` (1.8/2.5/4.5) → white. Issue #1524 tracks grey-gradient proposal, not merged in `abcdlsj/ghostty` `warren-ghosttykit-v1.0.0` nor `ghostty` `main`.

### 4. 1.8 → pure white
- Commit `07ce42c` set `1.8` to keep dark grey distinct from `234` warm-white flash. Local `warren` CLI capture of Codex shimmer (see below) showed `1.8` also white for `#2a2625` (contrast 1.27 <1.8).

### 5. 1 (disabled) → pure black
- Commit `118d330` / `3faeb09` removed/disable (`1`). Codex `38;2;0;0;0` stays black invisible, but spinner gradient preserved.
- User observed after `3faeb09` deletion: Working became pure black.

### 6. Output rewriting → grey but breaks other UI
- Attempt `571d282` in `WarrenGhosttyOutputWriter.swift:433` `remappedForVisibility`: scan `ESC[...m` SGR, replace `38;2;0;0;0→38;2;92;88;86` / `48;2;0;0;0` / `30→90` / `40→100` inside SGR only.
- Result: `0,0,0` became visible grey `#5c5856`, but Composer grey background `48;2;49;45;44` and other indexed blacks distorted (composer grey background, other color blocks turned grey). Reverted via `git reset --hard HEAD~1`.

### 7. Current baseline
- `git reset --hard origin/main` → `9b3e732` with `1.8` (white). Reset per user request to clean baseline for next iteration.

## Codex shimmer ground truth (warren CLI)
`warren session send/read` on live Codex TUI (`codexswitch` workspace, session `65f402e3-6b63-44c8-8051-431cd22e7736` and agent `91d6e0d4-b8a2-44ad-bca8-88b59ca70dfe`) captured:

```
38;2;215;213;211 #d7d5d3 warm-white flash
38;2;167;165;163 #a7a5a3
38;2;108;105;103 #6c6967
38;2;60;56;55  #3c3837
38;2;42;38;37  #2a2625 darkest
38;2;234;232;230 #eae8e6 Working static
```

Source: `codex-rs/tui/src/shimmer.rs:39-40` `base=default_fg (#eae8e6)` / `hl=default_bg (#151110)` via `terminal_palette.rs:100` OSC 10/11, `blend(hl, base, t*0.9)` → darkest `#2a2625` matches `0.9*21+0.1*234=42` etc. `default_fg/bg` answered by Warren `GhosttyAdapterTests.swift:299` OSC 10/11 probe.

With `minimum-contrast=1`, darkest `1.27>1` stays `#2a2625`; with `1.8`, `1.27<1.8` → white, gradient lost. This is why `ghostty` default `1` shows correct grey spinner.

## Ghostty shader reference
- `ghostty/src/renderer/shaders/glsl/common.glsl:21` `uniform float min_contrast`
- `common.glsl:97` / `shaders.metal:111` `contrasted_color` binary white/black
- `generic.zig:638` passes `config.@"minimum-contrast"`
- `cell_text.v.glsl:133` `if(min_contrast>1.0 && !NO_MIN_CONTRAST) color=contrasted_color(...)`
- `cell.zig:294` `noMinContrast` only for graphics elements, not text.

## Decision
Reset to `origin/main` (1.8) as clean baseline per user. Next step should keep `minimum-contrast` at `1` (or deleted) to preserve shimmer, and if pure-black `0,0,0` must be visible, narrow the rewrite to only `38;2;0;0;0` foreground truecolor (no `48`/`30`/`40`) or handle at the specific Codex status widget, not global SGR rewriting, to avoid Composer distortion.

## Verification
- `swift build --target GhosttyAdapter` OK
- `swift test --package-path Packages/GhosttyAdapter` 37 tests passed
- `warren session create/read` captures above ANSI; `ghostty` upstream shader verified via `raw.githubusercontent.com/abcdlsj/ghostty/main/src/renderer/shaders/glsl/common.glsl`
