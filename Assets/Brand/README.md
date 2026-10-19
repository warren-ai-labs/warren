# Warren Brand

## Core Concept

The icon is a `W` written as one round-capped stroke, whose
last stroke flicks out into an ember dot, on a caramel-brown rounded tile.

- The dot is the same dot Warren uses for Agent activity, so the mark carries
  the product's core signal.
- The middle peak sits lower than the outer arms, and the two outer arms rise
  to nearly the same height with mirrored slants, so the W does not lean.
- The dot sits on the extension of the last stroke, a fixed gap past its cap,
  so it reads as part of the stroke rather than a separate element.
- Optical sizing: the compact and micro sources draw the stroke and the dot
  heavier (stroke ×1.15 / ×1.45, dot ×1.25 / ×1.55) so the orange survives at
  32 and 16 px, while the master keeps the dot small so the W leads.
- The group is shifted so the rendered ink centroid sits on the tile's
  vertical center line.

## Source Files

- `warren-app-icon.svg`: 1024 × 1024 master source with a radial tile
  gradient, used at 64 px and above.
- `warren-app-icon-32.svg`: native 32 × 32 version on a flat tile, with a
  heavier stroke and dot for crisp small rendering.
- `warren-app-icon-16.svg`: native 16 × 16 micro version on a flat tile, with
  the heaviest stroke and dot.
- `warren-app-icon.png`: 1024 × 1024 preview and general bitmap.
- `Warren.icns`: macOS app icon. The sources are full-bleed tiles; the
  generator places them on the macOS icon grid (an 824 px tile inside a
  1024 px canvas, margins rounded to whole pixels at 16 and 32 px) so the icon
  matches other apps in the Dock. Web icons keep the full-bleed tile.
- `menubar-black.svg` / `menubar-white.svg`: source variants of the W on a
  transparent background. The macOS menu bar uses a single heavier template
  variant (stroke ×1.15, dot ×1.25, the same weight as the 32 px source) so the W stays visible at
  18 pt; AppKit recolors it automatically for light and dark menu bars.
  `scripts/build-app.sh` installs `menubar-black-18.png` /
  `menubar-black-36.png` into the app bundle as `menubar-template.png` and
  `menubar-template@2x.png`.

While the daemon is running, the menu bar item also shows a small breathing
status dot (agent activity green, `#7ec699`) in the bottom-right corner; it is
outlined by a thin charcoal ring for contrast and hidden in every other
state.

After modifying any source file, regenerate the derived assets:

```sh
mise run brand:assets
mise run web:build
```

The first command generates the macOS iconset, ICNS, Web favicons, and PWA
PNGs; the second builds `Web/public/` into `Web/dist/`. Derived files must not
be edited by hand.

## Colors

| Use | Value |
| --- | --- |
| Tile gradient (master) | `#4a2a1e` → `#2d1912` → `#170d0a` |
| Tile (32/16 px) | `#2d1912` |
| W stroke | `#f7ebe2` |
| Dot | `#ff8a5b` |

The artwork is a single polyline and a circle, so it stays crisp at any size;
the gradient is only used in the master source and replaced by a flat tile in
the compact and micro sources. The iOS app icon is rendered from the same
sources as an opaque square, because iOS applies its own mask.

## Alternate Colorways

Caramel is the default. `Alternates/` holds the same mark in four other
colorways for the App Icon setting: `charcoal` (cream W, ember dot), `ember`
(white W on an ember tile, dark dot), `paper` (near-black W on warm white,
ember dot) and `cream` (ember W on cream, dark dot). Each is a 1024 × 1024
master source with a rendered PNG beside it.

`mise run brand:assets` also renders, for every colorway including caramel,
the Dock image the desktop app swaps in at runtime
(`Packages/Desktop/Sources/WarrenDesktop/Resources/app-icon-<colorway>.png`,
on the macOS icon grid), and, for each alternate, a single-size iOS alternate
icon set (`AppIcon-<Colorway>.appiconset`). The desktop app only replaces the
running Dock icon; Finder keeps the bundled caramel icon, because rewriting
the bundle's icon would break its code signature. On iOS the system stores
the choice and shows its own confirmation.
