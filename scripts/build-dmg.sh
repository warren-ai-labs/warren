#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: scripts/build-dmg.sh <Warren.app> <Warren.dmg>

Build a drag-to-install disk image: the app, an Applications link, and a
background that explains the install step and the first-launch approval.
Laying out the window drives Finder through AppleScript, so the first run asks
the terminal for permission to control Finder.
EOF
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Warren disk images are supported only on macOS." >&2
    exit 69
fi
if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$1"
output_path="$2"
app_name="$(basename "$app_path")"
volume_name="Warren"
brand_root="$repository_root/Assets/Brand"

if [[ ! -d "$app_path/Contents" ]]; then
    echo "Not a macOS app bundle: $app_path" >&2
    exit 64
fi

work_root="$(mktemp -d)"
mount_point=""
cleanup() {
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        hdiutil detach "$mount_point" -force -quiet || true
    fi
    rm -rf "$work_root"
}
trap cleanup EXIT

staging="$work_root/staging"
mkdir -p "$staging/.background"
ditto "$app_path" "$staging/$app_name"
ln -s /Applications "$staging/Applications"
# One TIFF carrying both resolutions lets Finder pick the Retina background.
tiffutil -cathidpicheck "$brand_root/dmg-background.png" "$brand_root/dmg-background@2x.png" \
    -out "$staging/.background/background.tiff" >/dev/null 2>&1

# Leave headroom so Finder can write the window layout into the volume.
image_megabytes=$(( $(du -sm "$staging" | awk '{ print $1 }') + 32 ))
writable_image="$work_root/writable.dmg"
hdiutil create -quiet -srcfolder "$staging" -volname "$volume_name" -fs HFS+ \
    -format UDRW -size "${image_megabytes}m" -ov "$writable_image"

# A random mount point keeps a mounted Warren volume from colliding with this one.
mount_point="$(hdiutil attach "$writable_image" -readwrite -noverify -noautoopen \
    -mountrandom "$work_root" | awk -F '\t' '/Apple_HFS/ { print $NF }')"
if [[ -z "$mount_point" ]]; then
    echo "Could not mount $writable_image." >&2
    exit 70
fi

# The icon positions match the slots drawn in Assets/Brand/dmg-background.svg.
osascript - "$mount_point" "$app_name" <<'APPLESCRIPT'
on run argv
    set volumeFolder to POSIX file (item 1 of argv) as alias
    set appName to item 2 of argv
    tell application "Finder"
        open volumeFolder
        set theWindow to container window of volumeFolder
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        -- Bounds include the 28 pt title bar above the 660 x 420 background.
        set bounds of theWindow to {200, 120, 860, 568}
        set viewOptions to icon view options of theWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff" of volumeFolder
        set position of item appName of volumeFolder to {165, 175}
        set position of item "Applications" of volumeFolder to {495, 175}
        update volumeFolder without registering applications
        delay 1
        close theWindow
    end tell
end run
APPLESCRIPT

# Finder writes .DS_Store asynchronously; wait for it before detaching.
for _ in $(seq 1 20); do
    [[ -f "$mount_point/.DS_Store" ]] && break
    sleep 0.5
done
if [[ ! -f "$mount_point/.DS_Store" ]]; then
    echo "Finder did not save the window layout." >&2
    exit 70
fi
sync
hdiutil detach "$mount_point" -quiet
mount_point=""

rm -f "$output_path"
hdiutil convert -quiet "$writable_image" -format UDZO -imagekey zlib-level=9 -o "$output_path"
echo "Built $output_path"
