#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="${1:-$repository_root/.build/headless}"
mkdir -p "$output_directory"

build_version="$(bash "$repository_root/scripts/version.sh")"
build_revision="$(git -C "$repository_root" rev-parse HEAD 2>/dev/null || printf '%s' unknown)"
build_dirty=false
if [[ -n "$(git -C "$repository_root" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    build_dirty=true
fi
headless_ldflags="-X main.version=$build_version -X main.revision=$build_revision -X main.dirty=$build_dirty"
if [[ -n "${WARREN_GNAR_DEFAULT_EDGE:-}" ]]; then
    # The value is a public URL, not a credential. It is embedded only in the
    # release binary; user settings continue to store custom overrides.
    headless_ldflags+=" -X github.com/abcdlsj/warren/Headless/internal/releaseconfig.DefaultGnarEdge=${WARREN_GNAR_DEFAULT_EDGE}"
fi

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

if [[ "$(uname -m)" != arm64 ]]; then
    echo "Warren macOS builds require an arm64 Apple Silicon Mac." >&2
    exit 69
fi

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

compatibility_module_directory="$repository_root/Headless/cmd/ghostline-v0-compat"
compatibility_ghostline_directory="$(go -C "$compatibility_module_directory" list -m -f '{{.Dir}}' github.com/abcdlsj/ghostline)"
compatibility_library="$compatibility_ghostline_directory/third_party/lib/libghostty-vt.dylib"
if [[ ! -f "$compatibility_library" ]]; then
    echo "Missing v0.8 arm64 libghostty-vt.dylib: $compatibility_library" >&2
    exit 66
fi
validate_arm64_artifact "$compatibility_library"

build_macos_product() {
    local binary_name="$1"
    local destination="$2"

    GOOS=darwin \
    GOARCH=arm64 \
    CGO_ENABLED=1 \
    CGO_CFLAGS="-arch arm64 -mmacosx-version-min=13.0" \
    CGO_LDFLAGS="-arch arm64 -mmacosx-version-min=13.0" \
    go build \
        -ldflags "$headless_ldflags" \
        -o "$destination" \
        "$repository_root/Headless/cmd/$binary_name"
}

build_v0_compatibility() {
    GOOS=darwin \
    GOARCH=arm64 \
    CGO_ENABLED=1 \
    CGO_CFLAGS="-arch arm64 -mmacosx-version-min=13.0" \
    CGO_LDFLAGS="-arch arm64 -mmacosx-version-min=13.0" \
    go -C "$compatibility_module_directory" build \
        -o "$output_directory/ghostline-v0-compat" \
        .
}

build_macos_product warren-headless "$output_directory/warren-headless"
build_macos_product warren "$output_directory/warren"
build_v0_compatibility
cp -f "$output_directory/warren" "$output_directory/warren-cli"
validate_arm64_artifact "$output_directory/ghostline-v0-compat"
install -m 755 "$compatibility_library" "$output_directory/libghostline-v0-compat.dylib"
