#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
output_directory="${1:-$repository_root/.build/headless}"
mkdir -p "$output_directory"

build_version="$(bash "$repository_root/scripts/version.sh")"
headless_ldflags="-X main.version=$build_version"
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

ghostline_directory="$(go list -m -f '{{.Dir}}' github.com/abcdlsj/ghostline)"
ghostline_library="$ghostline_directory/third_party/lib/libghostty-vt.dylib"
library_directory="$output_directory/.ghostty-vt/arm64"
mkdir -p "$library_directory"
if [[ ! -f "$ghostline_library" ]]; then
    echo "Missing arm64 libghostty-vt.dylib: $ghostline_library" >&2
    exit 66
fi
validate_arm64_artifact "$ghostline_library"
install -m 755 "$ghostline_library" "$library_directory/libghostty-vt.dylib"

build_macos_product() {
    local binary_name="$1"
    local destination="$2"

    GOOS=darwin \
    GOARCH=arm64 \
    CGO_ENABLED=1 \
    CGO_CFLAGS="-arch arm64 -mmacosx-version-min=13.0" \
    CGO_LDFLAGS="-arch arm64 -mmacosx-version-min=13.0 -L$library_directory -Wl,-rpath,$library_directory" \
    go build \
        -ldflags "$headless_ldflags" \
        -o "$destination" \
        "$repository_root/Headless/cmd/$binary_name"
}

build_macos_product warren-headless "$output_directory/warren-headless"
build_macos_product warren "$output_directory/warren"
cp -f "$output_directory/warren" "$output_directory/warren-cli"
install -m 755 "$library_directory/libghostty-vt.dylib" "$output_directory/libghostty-vt.dylib"
