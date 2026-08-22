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
build_universal="${WARREN_BUILD_UNIVERSAL:-0}"
case "$build_universal" in
    0|1) ;;
    *)
        echo "WARREN_BUILD_UNIVERSAL must be 0 or 1: $build_universal" >&2
        exit 64
        ;;
esac

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Warren.app builds are supported only on macOS." >&2
    exit 69
fi

case "$(uname -m)" in
    arm64) native_arch=arm64 ;;
    x86_64) native_arch=x86_64 ;;
    *)
        echo "Unsupported macOS architecture: $(uname -m)" >&2
        exit 69
        ;;
esac

if [[ "$build_universal" == 1 ]]; then
    build_arches=(arm64 x86_64)
else
    build_arches=("$native_arch")
fi

if [[ "${WARREN_SKIP_WEB_BUILD:-0}" != "1" ]]; then
    bash "$repository_root/scripts/prepare-web.sh"
    npm --prefix "$repository_root/Web" run build
fi

arm_binary_directory=""
x86_binary_directory=""
resource_binary_directory=""
for architecture in "${build_arches[@]}"; do
    target_triple="${architecture}-apple-macosx13.0"
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
        --show-bin-path)"
    resource_binary_directory="$binary_directory"
    case "$architecture" in
        arm64) arm_binary_directory="$binary_directory" ;;
        x86_64) x86_binary_directory="$binary_directory" ;;
    esac
done

WARREN_BUILD_UNIVERSAL="$build_universal" \
    bash "$repository_root/scripts/build-headless.sh" "$repository_root/.build"

staging_path="$(mktemp -d "$repository_root/.build/Warren.app.staging.XXXXXX")"

cleanup() {
    rm -rf "$staging_path"
}
trap cleanup EXIT

mkdir -p "$staging_path/Contents/MacOS" "$staging_path/Contents/Resources"

install_macos_binary() {
    local product="$1"
    local destination="$2"

    if [[ "$build_universal" == 1 ]]; then
        lipo -create \
            "$arm_binary_directory/$product" \
            "$x86_binary_directory/$product" \
            -output "$destination"
    else
        install -m 755 "$resource_binary_directory/$product" "$destination"
    fi
}

install_macos_binary Warren "$staging_path/Contents/MacOS/Warren"
install_macos_binary WarrenDaemonMenuBar "$staging_path/Contents/MacOS/WarrenDaemonMenuBar"
install -m 755 "$repository_root/.build/warren-cli" "$staging_path/Contents/MacOS/warren-cli"
install -m 755 "$repository_root/.build/warren-headless" "$staging_path/Contents/MacOS/warren-headless"
install -m 644 "$repository_root/Support/Info.plist" "$staging_path/Contents/Info.plist"

# Release builds may ship the gnar worker inside Warren.app. The source tree
# remains usable without it, while WARREN_GNAR_BINARY gives CI/release jobs an
# explicit, reproducible input. A sibling ../gnar checkout is accepted for
# local packaging only; Warren never edits that checkout or its credentials.
gnar_binary="${WARREN_GNAR_BINARY:-}"
if [[ -n "$gnar_binary" ]]; then
    if [[ ! -f "$gnar_binary" || ! -x "$gnar_binary" ]]; then
        echo "WARREN_GNAR_BINARY must name an executable file: $gnar_binary" >&2
        exit 66
    fi
else
    for candidate in \
        "$repository_root/../gnar/target/release/gnar" \
        "$repository_root/../gnar/gnar"; do
        if [[ -f "$candidate" && -x "$candidate" ]]; then
            gnar_binary="$candidate"
            break
        fi
    done
fi

validate_universal_binary() {
    local binary="$1"
    local description

    description="$(lipo -info "$binary" 2>&1)" || {
        echo "Cannot inspect architecture: $binary" >&2
        exit 65
    }
    if ! grep -Eq '(^|[[:space:]])arm64([[:space:]]|$)' <<< "$description" ||
        ! grep -Eq '(^|[[:space:]])x86_64([[:space:]]|$)' <<< "$description"; then
        echo "$binary must contain arm64 and x86_64 (lipo: $description)" >&2
        exit 65
    fi
}

if [[ -n "$gnar_binary" ]]; then
    if [[ "$build_universal" == 1 ]]; then
        validate_universal_binary "$gnar_binary"
    fi
    install -m 755 "$gnar_binary" "$staging_path/Contents/Resources/gnar"
else
    echo "warning: no gnar binary found; Warren will use WARREN_GNAR_PATH/system discovery" >&2
fi

if [[ ! -f "$repository_root/.build/libghostty-vt.dylib" ]]; then
    echo "Missing build-headless output: $repository_root/.build/libghostty-vt.dylib" >&2
    exit 66
fi
if [[ "$build_universal" == 1 ]]; then
    validate_universal_binary "$repository_root/.build/libghostty-vt.dylib"
fi
mkdir -p "$staging_path/Contents/Frameworks"
install -m 755 \
    "$repository_root/.build/libghostty-vt.dylib" \
    "$staging_path/Contents/Frameworks/libghostty-vt.dylib"

headless_binary="$staging_path/Contents/MacOS/warren-headless"
# warren-headless links libghostty-vt.dylib through an rpath that Go writes
# pointing at the local build directory. Strip that machine-specific rpath
# and bundle the dylib inside the app so the release runs on other Macs.
strip_and_add_rpath() {
    local binary="$1"
    local old_rpath

    while IFS= read -r old_rpath; do
        [[ -n "$old_rpath" ]] || continue
        install_name_tool -delete_rpath "$old_rpath" "$binary"
    done < <(
        otool -l "$binary" |
            awk '/LC_RPATH/{rpath=1} rpath && /path /{print $2; rpath=0}'
    )
    install_name_tool -add_rpath @executable_path/../Frameworks "$binary"
}

if [[ "$build_universal" == 1 ]]; then
    rpath_staging_path="$(mktemp -d "$repository_root/.build/Warren.app.rpath.XXXXXX")"
    for architecture in arm64 x86_64; do
        thin_binary="$rpath_staging_path/warren-headless-$architecture"
        lipo -thin "$architecture" "$headless_binary" -output "$thin_binary"
        strip_and_add_rpath "$thin_binary"
    done
    chmod u+w "$headless_binary"
    lipo -create \
        "$rpath_staging_path/warren-headless-arm64" \
        "$rpath_staging_path/warren-headless-x86_64" \
        -output "$headless_binary"
    rm -rf "$rpath_staging_path"
else
    strip_and_add_rpath "$headless_binary"
fi

build_variant="build"
if [[ "$configuration" == release ]]; then
    build_variant="release"
fi
printf '%s\n' "$build_variant" > "$staging_path/Contents/Resources/build-variant.txt"

install -m 644 "$repository_root/Assets/Brand/Warren.icns" "$staging_path/Contents/Resources/Warren.icns"
install -m 755 "$repository_root/Support/Raycast/warren-terminal.sh" "$staging_path/Contents/Resources/warren-terminal.sh"
install -m 644 "$repository_root/Assets/Brand/warren-app-icon.png" "$staging_path/Contents/Resources/warren-terminal.png"
install -m 644 "$repository_root/Assets/Brand/menubar-black-18.png" "$staging_path/Contents/Resources/menubar-template.png"
install -m 644 "$repository_root/Assets/Brand/menubar-black-36.png" "$staging_path/Contents/Resources/menubar-template@2x.png"
cp -R \
    "$resource_binary_directory/WarrenDesktop_WarrenDesktop.bundle" \
    "$staging_path/Contents/Resources/WarrenDesktop_WarrenDesktop.bundle"
cp -R "$repository_root/Web/dist/." "$staging_path/Contents/Resources/"

bash "$repository_root/scripts/sign-app.sh" "$staging_path"
rm -rf "$app_path"
mv "$staging_path" "$app_path"
trap - EXIT

echo "Built $app_path"
