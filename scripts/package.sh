#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
version="0.3.0"

bash "$repository_root/scripts/build-app.sh" release

archive="$repository_root/Warren-$version.zip"
rm -f "$archive"
ditto -c -k --keepParent "$repository_root/Warren.app" "$archive"
echo "Packaged $archive"
