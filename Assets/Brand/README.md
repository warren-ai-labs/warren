# Warren Brand

## Core Concept

The icon is a slanted `W` built from four straight line segments, drawn like a
metal brush stroke on a charcoal rounded tile.

- Each stroke has a pronounced width taper: the left edge runs thin to thick,
  the inner strokes thin toward the center valley, and the right edge runs
  thick to thin.
- The two inner strokes carry the bright silver highlight; the outer strokes
  stay in the darker metal tone, keeping a selective metallic feel.
- The mark is optically centered with a barely perceptible shift to the right.

## Source Files

- `warren-app-icon.svg`: 1024 × 1024 master source with metallic gradients,
  used at 64 px and above.
- `warren-app-icon-32.svg`: native 32 × 32 version with flat silver tones for
  crisp small rendering.
- `warren-app-icon-16.svg`: native 16 × 16 micro version with flat silver
  tones.
- `warren-app-icon.png`: 1024 × 1024 preview and general bitmap.
- `Warren.icns`: macOS app icon. The sources are full-bleed tiles; the
  generator places them on the macOS icon grid (an 824 px tile inside a
  1024 px canvas, margins rounded to whole pixels at 16 and 32 px) so the icon
  matches other apps in the Dock. Web icons keep the full-bleed tile.
- `menubar-black.svg` / `menubar-white.svg`: source variants of the W on a
  transparent background. The macOS menu bar uses a single heavier template
  variant (about 1.5× stroke width, still tapered) so the W stays visible at
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
| Tile rim | `#121110` |
| Tile background | `#1c1918` |
| Mark shadow | `#0d0c0b` |
| Dark metal | `#8a8376` / `#c4bdb0` / `#6b655c` |
| Bright metal | `#7b756a` / `#c7c0b2` / `#f2eee5` / `#fbf9f3` / `#b8b1a4` / `#5c574f` |
| Flat light (32/16 px) | `#d8d2c3` |
| Flat dark (32/16 px) | `#8a8376` |

The artwork is pure straight-line geometry, so it stays crisp at any size;
gradients are only used in the master source and replaced by flat tones in
the compact and micro sources.
