#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
brand_root="$repository_root/Assets/Brand"
web_public_root="$repository_root/Web/public"
iconset_root="$brand_root/Warren.iconset"
master_svg="$brand_root/warren-app-icon.svg"
compact_svg="$brand_root/warren-app-icon-32.svg"
micro_svg="$brand_root/warren-app-icon-16.svg"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert is required to generate Warren brand assets" >&2
    exit 1
fi

render() {
    local source="$1"
    local size="$2"
    local destination="$3"
    rsvg-convert --width "$size" --height "$size" --output "$destination" "$source"
}

mkdir -p "$iconset_root" "$web_public_root"

render "$master_svg" 1024 "$brand_root/warren-app-icon.png"

# The sources are full-bleed tiles, which the Web touch icons need because
# the platform masks them. macOS does not mask: its icon grid puts an 824 px
# tile inside a 1024 px canvas, so the macOS renders get that margin here.
# The optical-size sources are drawn on whole pixels, so their margin is
# rounded to whole pixels too rather than scaled exactly.
macos_grid_root="$(mktemp -d)"
trap 'rm -rf "$macos_grid_root"' EXIT

macos_grid() {
    local source="$1"
    local destination="$2"
    local margin="$3"
    local extent
    extent="$(sed -n 's/.*viewBox="0 0 \([0-9]*\) .*/\1/p' "$source" | head -n 1)"
    {
        sed -n '1p' "$source"
        awk -v extent="$extent" -v margin="$margin" 'BEGIN { printf "<g transform=\"translate(%g %g) scale(%g)\">\n", margin, margin, (extent - 2 * margin) / extent }'
        sed '1d;$d' "$source"
        printf '</g>\n</svg>\n'
    } > "$destination"
}

macos_master_svg="$macos_grid_root/master.svg"
macos_compact_svg="$macos_grid_root/compact.svg"
macos_micro_svg="$macos_grid_root/micro.svg"
macos_grid "$master_svg" "$macos_master_svg" 100
macos_grid "$compact_svg" "$macos_compact_svg" 3
macos_grid "$micro_svg" "$macos_micro_svg" 1

# macOS uses optical-size sources rather than shrinking the detailed master
# through the two sizes where its 32 px construction grid lands on half pixels.
render "$macos_micro_svg" 16 "$iconset_root/icon_16x16.png"
render "$macos_compact_svg" 32 "$iconset_root/icon_16x16@2x.png"
render "$macos_compact_svg" 32 "$iconset_root/icon_32x32.png"
render "$macos_master_svg" 64 "$iconset_root/icon_32x32@2x.png"
render "$macos_master_svg" 128 "$iconset_root/icon_128x128.png"
render "$macos_master_svg" 256 "$iconset_root/icon_128x128@2x.png"
render "$macos_master_svg" 256 "$iconset_root/icon_256x256.png"
render "$macos_master_svg" 512 "$iconset_root/icon_256x256@2x.png"
render "$macos_master_svg" 512 "$iconset_root/icon_512x512.png"
render "$macos_master_svg" 1024 "$iconset_root/icon_512x512@2x.png"

if command -v iconutil >/dev/null 2>&1; then
    iconutil --convert icns --output "$brand_root/Warren.icns" "$iconset_root"
else
    echo "warning: iconutil not found; skipped Warren.icns" >&2
fi

cp "$master_svg" "$web_public_root/icon.svg"
render "$micro_svg" 16 "$web_public_root/favicon-16.png"
render "$compact_svg" 32 "$web_public_root/favicon-32.png"
render "$master_svg" 180 "$web_public_root/apple-touch-icon.png"
render "$master_svg" 192 "$web_public_root/icon-192.png"
render "$master_svg" 512 "$web_public_root/icon-512.png"
