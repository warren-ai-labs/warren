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

if [[ "${WARREN_SKIP_WEB_BUILD:-0}" != "1" ]]; then
    bash "$repository_root/scripts/prepare-web.sh"
    npm --prefix "$repository_root/Web" run build
fi

swift build \
    --package-path "$repository_root" \
    --configuration "$configuration" \
    --product Warren

swift build \
    --package-path "$repository_root" \
    --configuration "$configuration" \
    --product WarrenDaemonMenuBar

build_version="$(bash "$repository_root/scripts/version.sh")"
go build -ldflags "-X main.version=$build_version" -o "$repository_root/.build/warren-cli" "$repository_root/Headless/cmd/warren"
go build -ldflags "-X main.version=$build_version" -o "$repository_root/.build/warren-headless" "$repository_root/Headless/cmd/warren-headless"

binary_directory="$(
    swift build \
        --package-path "$repository_root" \
        --configuration "$configuration" \
        --show-bin-path
)"
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
install -m 644 "$repository_root/Support/Info.plist" "$staging_path/Contents/Info.plist"
install -m 644 "$repository_root/Assets/Brand/Warren.icns" "$staging_path/Contents/Resources/Warren.icns"
install -m 755 "$repository_root/Support/Raycast/warren-terminal.sh" "$staging_path/Contents/Resources/warren-terminal.sh"
install -m 644 "$repository_root/Assets/Brand/warren-app-icon.png" "$staging_path/Contents/Resources/warren-terminal.png"
install -m 644 "$repository_root/Assets/Brand/menubar-black-18.png" "$staging_path/Contents/Resources/menubar-template.png"
install -m 644 "$repository_root/Assets/Brand/menubar-black-36.png" "$staging_path/Contents/Resources/menubar-template@2x.png"
cp -R \
    "$binary_directory/WarrenDesktop_WarrenDesktop.bundle" \
    "$staging_path/Contents/Resources/WarrenDesktop_WarrenDesktop.bundle"
cp -R "$repository_root/Web/dist/." "$staging_path/Contents/Resources/"

# warren-headless links libghostty-vt.dylib through an rpath that Go writes
# pointing at the local module cache (~/go/pkg/mod/...). Strip that
# machine-specific rpath and bundle the dylib inside the app so the release
# runs on other Macs.
ghostline_dir="$(
    cd "$repository_root"
    go list -m -f '{{.Dir}}' github.com/abcdlsj/ghostline
)"
mkdir -p "$staging_path/Contents/Frameworks"
install -m 755 \
    "$ghostline_dir/third_party/lib/libghostty-vt.dylib" \
    "$staging_path/Contents/Frameworks/libghostty-vt.dylib"

headless_binary="$staging_path/Contents/MacOS/warren-headless"
while IFS= read -r old_rpath; do
    [[ -n "$old_rpath" ]] || continue
    install_name_tool -delete_rpath "$old_rpath" "$headless_binary"
done < <(
    otool -l "$headless_binary" |
        awk '/LC_RPATH/{rpath=1} rpath && /path /{print $2; rpath=0}'
)
install_name_tool -add_rpath @executable_path/../Frameworks "$headless_binary"

build_variant="build"
if [[ "$configuration" == "release" ]]; then
    build_variant="release"
fi
printf '%s\n' "$build_variant" > "$staging_path/Contents/Resources/build-variant.txt"

bash "$repository_root/scripts/sign-app.sh" "$staging_path"
rm -rf "$app_path"
mv "$staging_path" "$app_path"
trap - EXIT

echo "Built $app_path"
