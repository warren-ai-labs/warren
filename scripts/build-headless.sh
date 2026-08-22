#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="${1:-$repository_root/.build/headless}"
mkdir -p "$output_directory"

build_universal="${WARREN_BUILD_UNIVERSAL:-0}"
case "$build_universal" in
    0|1) ;;
    *)
        echo "WARREN_BUILD_UNIVERSAL must be 0 or 1: $build_universal" >&2
        exit 64
        ;;
esac

build_version="$(bash "$repository_root/scripts/version.sh")"
headless_ldflags="-X main.version=$build_version"
if [[ -n "${WARREN_GNAR_DEFAULT_EDGE:-}" ]]; then
    # The value is a public URL, not a credential. It is embedded only in the
    # release binary; user settings continue to store custom overrides.
    headless_ldflags+=" -X github.com/abcdlsj/warren/Headless/internal/releaseconfig.DefaultGnarEdge=${WARREN_GNAR_DEFAULT_EDGE}"
fi

fail() {
    echo "error: $*" >&2
    exit 66
}

require_architecture() {
    local binary="$1"
    local architecture="$2"
    local description

    [[ -f "$binary" ]] || fail "missing Mach-O artifact: $binary"
    description="$(lipo -info "$binary" 2>&1)" || fail "cannot inspect architecture: $binary"
    if ! grep -Eq "(^|[[:space:]])${architecture}([[:space:]]|$)" <<< "$description"; then
        fail "$binary does not contain $architecture (lipo: $description)"
    fi
}

extract_architecture() {
    local source="$1"
    local architecture="$2"
    local destination="$3"
    local description

    [[ -f "$source" ]] || fail "missing libghostty-vt dylib: $source"
    description="$(lipo -info "$source" 2>&1)" || fail "cannot inspect libghostty-vt: $source"
    mkdir -p "$(dirname "$destination")"
    [[ -e "$destination" ]] && chmod u+w "$destination"
    if [[ "$description" == Non-fat* ]]; then
        if ! grep -Eq "(^|[[:space:]])${architecture}([[:space:]]|$)" <<< "$description"; then
            fail "$source is not a $architecture dylib (lipo: $description)"
        fi
        install -m 755 "$source" "$destination"
    else
        lipo -thin "$architecture" "$source" -output "$destination"
    fi
    require_architecture "$destination" "$architecture"
}

find_ghostty_dylib() {
    local search_directory="$1"
    local candidate

    while IFS= read -r candidate; do
        [[ -f "$candidate" && ! -L "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done < <(find "$search_directory" -maxdepth 2 -type f -name 'libghostty-vt*.dylib' -print 2>/dev/null | sort)
    return 1
}

resolve_x86_64_library() {
    local library="${WARREN_GHOSTTY_VT_X86_64:-}"
    local ghostty_directory="${WARREN_GHOSTTY_DIR:-}"
    local candidate
    local build_directory="$output_directory/.ghostty-vt/x86_64"

    if [[ -z "$library" && -n "${WARREN_GHOSTTY_VT_DIR:-}" ]]; then
        for candidate in \
            "$WARREN_GHOSTTY_VT_DIR/x86_64/libghostty-vt.dylib" \
            "$WARREN_GHOSTTY_VT_DIR/lib/libghostty-vt.dylib" \
            "$WARREN_GHOSTTY_VT_DIR/libghostty-vt.dylib"; do
            if [[ -f "$candidate" ]]; then
                library="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$library" ]]; then
        # Resolve the optional Ghostty checkout relative to this repository so
        # release instructions remain portable across machines.
        if [[ -z "$ghostty_directory" && -f "$repository_root/../ghostty/build.zig" ]]; then
            ghostty_directory="$repository_root/../ghostty"
        fi
        if [[ -n "$ghostty_directory" && -f "$ghostty_directory/build.zig" ]]; then
            command -v zig >/dev/null 2>&1 || fail "zig 0.16+ is required to build the x86_64 libghostty-vt dylib"
            candidate=""
            if [[ -d "$build_directory/lib" ]]; then
                candidate="$(find_ghostty_dylib "$build_directory/lib" || true)"
            fi
            if [[ -z "$candidate" ]]; then
                echo "==> build libghostty-vt for x86_64 from $ghostty_directory" >&2
                mkdir -p "$build_directory"
                (
                    cd "$ghostty_directory"
                    zig build \
                        -Dtarget=x86_64-macos \
                        -Doptimize=ReleaseFast \
                        -Demit-lib-vt=true \
                        --prefix "$build_directory"
                ) >&2
                candidate="$(find_ghostty_dylib "$build_directory/lib" || true)"
            fi
            [[ -n "$candidate" ]] && library="$candidate"
        fi
    fi

    [[ -n "$library" ]] || fail "no x86_64 libghostty-vt.dylib found; set WARREN_GHOSTTY_DIR to a Ghostty checkout or WARREN_GHOSTTY_VT_X86_64 to a prebuilt dylib"
    printf '%s\n' "$library"
}

prepare_macos_libraries() {
    local ghostline_directory
    local arm_library
    local x86_library
    local library_directory="$output_directory/.ghostty-vt"

    ghostline_directory="$(go list -m -f '{{.Dir}}' github.com/abcdlsj/ghostline)"
    arm_library="$ghostline_directory/third_party/lib/libghostty-vt.dylib"
    mkdir -p "$library_directory"
    extract_architecture "$arm_library" arm64 "$library_directory/arm64/libghostty-vt.dylib"

    if [[ "$build_universal" == 1 || "$(go env GOARCH)" == amd64 ]]; then
        x86_library="$(resolve_x86_64_library)"
        extract_architecture "$x86_library" x86_64 "$library_directory/x86_64/libghostty-vt.dylib"
    fi

    if [[ "$build_universal" == 1 ]]; then
        [[ -e "$output_directory/libghostty-vt.dylib" ]] && chmod u+w "$output_directory/libghostty-vt.dylib"
        lipo -create \
            "$library_directory/arm64/libghostty-vt.dylib" \
            "$library_directory/x86_64/libghostty-vt.dylib" \
            -output "$output_directory/libghostty-vt.dylib"
        require_architecture "$output_directory/libghostty-vt.dylib" arm64
        require_architecture "$output_directory/libghostty-vt.dylib" x86_64
    elif [[ "$(go env GOARCH)" == amd64 ]]; then
        install -m 755 "$library_directory/x86_64/libghostty-vt.dylib" "$output_directory/libghostty-vt.dylib"
    else
        install -m 755 "$library_directory/arm64/libghostty-vt.dylib" "$output_directory/libghostty-vt.dylib"
    fi
}

build_go_product() {
    local go_arch="$1"
    local mac_arch="$2"
    local binary_name="$3"
    local destination="$4"
    local library_directory="$output_directory/.ghostty-vt/$mac_arch"

    mkdir -p "$(dirname "$destination")"
    GOOS=darwin \
    GOARCH="$go_arch" \
    CGO_ENABLED=1 \
    CGO_CFLAGS="-arch $mac_arch -mmacosx-version-min=13.0" \
    CGO_LDFLAGS="-arch $mac_arch -mmacosx-version-min=13.0 -L$library_directory -Wl,-rpath,$library_directory" \
    go build \
        -ldflags "$headless_ldflags" \
        -o "$destination" \
        "$repository_root/Headless/cmd/$binary_name"
}

build_non_macos() {
    go build \
        -ldflags "$headless_ldflags" \
        -o "$output_directory/warren-headless" \
        "$repository_root/Headless/cmd/warren-headless"
    go build \
        -ldflags "$headless_ldflags" \
        -o "$output_directory/warren" \
        "$repository_root/Headless/cmd/warren"
    cp -f "$output_directory/warren" "$output_directory/warren-cli"
}

if [[ "$(go env GOOS)" != darwin ]]; then
    build_non_macos
    exit 0
fi

command -v lipo >/dev/null 2>&1 || fail "lipo is required for macOS builds"
prepare_macos_libraries

if [[ "$build_universal" == 1 ]]; then
    build_go_product arm64 arm64 warren-headless "$output_directory/.go/arm64/warren-headless"
    build_go_product amd64 x86_64 warren-headless "$output_directory/.go/x86_64/warren-headless"
    build_go_product arm64 arm64 warren "$output_directory/.go/arm64/warren"
    build_go_product amd64 x86_64 warren "$output_directory/.go/x86_64/warren"
    lipo -create \
        "$output_directory/.go/arm64/warren-headless" \
        "$output_directory/.go/x86_64/warren-headless" \
        -output "$output_directory/warren-headless"
    lipo -create \
        "$output_directory/.go/arm64/warren" \
        "$output_directory/.go/x86_64/warren" \
        -output "$output_directory/warren"
    cp -f "$output_directory/warren" "$output_directory/warren-cli"
    require_architecture "$output_directory/warren-headless" arm64
    require_architecture "$output_directory/warren-headless" x86_64
    require_architecture "$output_directory/warren" arm64
    require_architecture "$output_directory/warren" x86_64
else
    native_go_arch="$(go env GOARCH)"
    case "$native_go_arch" in
        arm64) native_mac_arch=arm64 ;;
        amd64) native_mac_arch=x86_64 ;;
        *) fail "unsupported macOS Go architecture: $native_go_arch" ;;
    esac
    build_go_product "$native_go_arch" "$native_mac_arch" warren-headless "$output_directory/warren-headless"
    build_go_product "$native_go_arch" "$native_mac_arch" warren "$output_directory/warren"
    cp -f "$output_directory/warren" "$output_directory/warren-cli"
fi
