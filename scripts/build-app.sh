#!/usr/bin/env bash

set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 64
        ;;
esac

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repository_root/Warren.app"
build_version="$(bash "$repository_root/scripts/version.sh")"
build_revision="$(git -C "$repository_root" rev-parse HEAD 2>/dev/null || printf '%s' unknown)"
build_dirty=false
if [[ -n "$(git -C "$repository_root" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    build_dirty=true
fi

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Warren.app builds are supported only on macOS." >&2
    exit 69
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "Warren macOS builds require an arm64 Apple Silicon Mac." >&2
    exit 69
fi

target_triple="arm64-apple-macosx13.0"
if [[ "${WARREN_SKIP_WEB_BUILD:-0}" != "1" ]]; then
    bash "$repository_root/scripts/prepare-web.sh"
    npm --prefix "$repository_root/Web" run build
fi

swift build \
    --package-path "$repository_root" \
    --configuration "$configuration" \
    --triple "$target_triple" \
    --product Warren

swift build \
    --package-path "$repository_root" \
    --configuration "$configuration" \
    --triple "$target_triple" \
    --product WarrenDaemonMenuBar

binary_directory="$(swift build \
    --package-path "$repository_root" \
    --configuration "$configuration" \
    --triple "$target_triple" \
    --show-bin-path
)"

bash "$repository_root/scripts/build-headless.sh" "$repository_root/.build"

staging_path="$(mktemp -d "$repository_root/.build/Warren.app.staging.XXXXXX")"

cleanup() {
    rm -rf "$staging_path"
}
trap cleanup EXIT

mkdir -p "$staging_path/Contents/MacOS" "$staging_path/Contents/Resources"
install -m 755 "$binary_directory/Warren" "$staging_path/Contents/MacOS/Warren"
install -m 755 "$binary_directory/WarrenDaemonMenuBar" "$staging_path/Contents/MacOS/WarrenDaemonMenuBar"
install -m 755 "$repository_root/.build/warren-cli" "$staging_path/Contents/MacOS/warren-cli"
install -m 755 "$repository_root/.build/warren-headless" "$staging_path/Contents/MacOS/warren-headless"
install -m 755 "$repository_root/.build/warren-ssh-tunnel" "$staging_path/Contents/MacOS/warren-ssh-tunnel"
install -m 644 "$repository_root/Support/Info.plist" "$staging_path/Contents/Info.plist"
plutil -replace WarrenBuildVersion -string "$build_version" "$staging_path/Contents/Info.plist"
plutil -replace WarrenBuildRevision -string "$build_revision" "$staging_path/Contents/Info.plist"
plutil -replace WarrenBuildDirty -bool "$build_dirty" "$staging_path/Contents/Info.plist"

validate_arm64_artifact() {
    local artifact="$1"
    local architectures
    architectures="$(lipo -archs "$artifact" 2>&1)" || {
        echo "Cannot inspect macOS architecture: $artifact" >&2
        exit 65
    }
    if [[ "$architectures" != arm64 ]]; then
        echo "$artifact must contain only arm64 (lipo: $architectures)" >&2
        exit 65
    fi
}

install -m 644 "$repository_root/Assets/Brand/Warren.icns" "$staging_path/Contents/Resources/Warren.icns"
install -m 755 "$repository_root/Support/Raycast/warren-terminal.sh" "$staging_path/Contents/Resources/warren-terminal.sh"
install -m 644 "$repository_root/Assets/Brand/warren-app-icon.png" "$staging_path/Contents/Resources/warren-terminal.png"
install -m 644 "$repository_root/Assets/Brand/menubar-black-18.png" "$staging_path/Contents/Resources/menubar-template.png"
install -m 644 "$repository_root/Assets/Brand/menubar-black-36.png" "$staging_path/Contents/Resources/menubar-template@2x.png"
if [[ -d "$repository_root/Support/terminfo" ]]; then
    mkdir -p "$staging_path/Contents/Resources/terminfo"
    cp -R "$repository_root/Support/terminfo/." "$staging_path/Contents/Resources/terminfo/"
fi
cp -R \
    "$binary_directory/WarrenDesktop_WarrenDesktop.bundle" \
    "$staging_path/Contents/Resources/WarrenDesktop_WarrenDesktop.bundle"
cp -R "$repository_root/Web/dist/." "$staging_path/Contents/Resources/"

# The desktop and Web clients use this marker to distinguish debug previews
# from release installs. Write it after copying Web assets so a stale marker
# from Web/dist cannot override the selected configuration.
build_variant="build"
if [[ "$configuration" == release ]]; then
    build_variant="release"
fi
printf '%s\n' "$build_variant" > "$staging_path/Contents/Resources/build-variant.txt"

bash "$repository_root/scripts/sign-app.sh" "$staging_path"
rm -rf "$app_path"
mv "$staging_path" "$app_path"
trap - EXIT

echo "Built $app_path"
