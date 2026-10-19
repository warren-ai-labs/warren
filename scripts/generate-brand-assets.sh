#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
brand_root="$repository_root/Assets/Brand"
web_public_root="$repository_root/Web/public"
iconset_root="$brand_root/Warren.iconset"
master_svg="$brand_root/warren-app-icon.svg"
compact_svg="$brand_root/warren-app-icon-32.svg"
micro_svg="$brand_root/warren-app-icon-16.svg"
alternates_root="$brand_root/Alternates"
desktop_resources_root="$repository_root/Packages/Desktop/Sources/WarrenDesktop/Resources"
ios_assets_root="$repository_root/Packages/WarrenIOS/Sources/WarrenIOSApp/Resources/Assets.xcassets"

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

# The disk image window background, at 1x and 2x for Retina Finder windows.
rsvg-convert --width 660 --height 420 --output "$brand_root/dmg-background.png" "$brand_root/dmg-background.svg"
rsvg-convert --width 1320 --height 840 --output "$brand_root/dmg-background@2x.png" "$brand_root/dmg-background.svg"

cp "$master_svg" "$web_public_root/icon.svg"
render "$micro_svg" 16 "$web_public_root/favicon-16.png"
render "$compact_svg" 32 "$web_public_root/favicon-32.png"
render "$master_svg" 180 "$web_public_root/apple-touch-icon.png"
render "$master_svg" 192 "$web_public_root/icon-192.png"
render "$master_svg" 512 "$web_public_root/icon-512.png"

# iOS masks its app icons itself and rejects transparency, so every iOS icon is
# the full-bleed tile flattened to an opaque square. The smallest sizes use the
# compact source, as macOS does.
square() {
    local source="$1"
    local destination="$2"
    # The tile is the only rounded element in the sources.
    sed -E 's/ rx="[0-9.]+"/ rx="0"/' "$source" > "$destination"
}

opaque() {
    local source="$1"
    local size="$2"
    local destination="$3"
    rsvg-convert --width "$size" --height "$size" --background-color "#2d1912" --output "$destination" "$source"
}

# The App Icon setting previews a colorway at Home Screen size. App icon sets
# are not loadable as images, so each colorway also gets a small imageset the
# picker can draw.
preview_set() {
    local source="$1"
    local display_name="$2"
    local set="$ios_assets_root/AppIconPreview-$display_name.imageset"
    mkdir -p "$set"
    render "$source" 60 "$set/icon.png"
    render "$source" 120 "$set/icon@2x.png"
    render "$source" 180 "$set/icon@3x.png"
    cat > "$set/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "icon@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "icon@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : {
    "author" : "warren",
    "version" : 1
  }
}
JSON
}

ios_master_svg="$macos_grid_root/ios-master.svg"
ios_compact_svg="$macos_grid_root/ios-compact.svg"
square "$master_svg" "$ios_master_svg"
square "$compact_svg" "$ios_compact_svg"
ios_icon_root="$ios_assets_root/AppIcon.appiconset"
for entry in 20:1 20:2 20:3 29:1 29:2 29:3 40:1 40:2 40:3 60:2 60:3 76:1 76:2 83.5:2; do
    points="${entry%%:*}"
    scale="${entry##*:}"
    pixels="$(awk -v points="$points" -v scale="$scale" 'BEGIN { printf "%d", points * scale + 0.5 }')"
    source="$ios_master_svg"
    if [ "$pixels" -le 40 ]; then
        source="$ios_compact_svg"
    fi
    opaque "$source" "$pixels" "$ios_icon_root/icon-${points}x${points}@${scale}x.png"
done
opaque "$ios_master_svg" 1024 "$ios_icon_root/icon-1024.png"
preview_set "$ios_master_svg" "Caramel"

# The alternate colorways. The default (caramel) is the master above; each
# alternate gets a preview PNG, a Dock image for the desktop app's icon choice
# (on the macOS grid, like the ICNS) and a single-size iOS alternate icon set.
mkdir -p "$desktop_resources_root"
macos_grid "$master_svg" "$macos_grid_root/caramel.svg" 100
render "$macos_grid_root/caramel.svg" 512 "$desktop_resources_root/app-icon-caramel.png"
for alternate_svg in "$alternates_root"/warren-app-icon-*.svg; do
    colorway="$(basename "$alternate_svg" .svg)"
    colorway="${colorway#warren-app-icon-}"
    display_name="$(printf '%s' "${colorway:0:1}" | tr '[:lower:]' '[:upper:]')${colorway:1}"
    render "$alternate_svg" 1024 "$alternates_root/warren-app-icon-$colorway.png"
    macos_grid "$alternate_svg" "$macos_grid_root/$colorway.svg" 100
    render "$macos_grid_root/$colorway.svg" 512 "$desktop_resources_root/app-icon-$colorway.png"
    icon_set="$ios_assets_root/AppIcon-$display_name.appiconset"
    mkdir -p "$icon_set"
    square "$alternate_svg" "$macos_grid_root/ios-$colorway.svg"
    preview_set "$macos_grid_root/ios-$colorway.svg" "$display_name"
    rsvg-convert --width 1024 --height 1024 --background-color "#ffffff" \
        --output "$icon_set/icon-1024.png" "$macos_grid_root/ios-$colorway.svg"
    cat > "$icon_set/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : {
    "author" : "warren",
    "version" : 1
  }
}
JSON
done
