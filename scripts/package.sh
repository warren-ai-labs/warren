#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
version="0.8.0"

# This is the release-only packaging entry point. Keep the Universal default
# explicit so Intel coverage cannot be lost through an accidental arm64-only
# release build; build-app.sh stamps the resulting bundle as `release`.
WARREN_BUILD_UNIVERSAL="${WARREN_BUILD_UNIVERSAL:-1}" \
    bash "$repository_root/scripts/build-app.sh" release

archive="$repository_root/Warren-$version.zip"
rm -f "$archive"
ditto -c -k --keepParent "$repository_root/Warren.app" "$archive"
echo "Packaged $archive"
