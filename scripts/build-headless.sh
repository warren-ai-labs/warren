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

go build \
    -ldflags "$headless_ldflags" \
    -o "$output_directory/warren-headless" \
    "$repository_root/Headless/cmd/warren-headless"
go build \
    -ldflags "$headless_ldflags" \
    -o "$output_directory/warren" \
    "$repository_root/Headless/cmd/warren"
