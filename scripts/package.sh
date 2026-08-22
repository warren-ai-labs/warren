#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
version="0.8.0"

# This is the release-only packaging entry point. build-app.sh stamps the
# resulting arm64 bundle as `release`.
bash "$repository_root/scripts/build-app.sh" release

archive="$repository_root/Warren-$version.zip"
rm -f "$archive"
ditto -c -k --keepParent "$repository_root/Warren.app" "$archive"
echo "Packaged $archive"
