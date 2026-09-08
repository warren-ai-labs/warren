#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

release_tag="$(git -C "$repository_root" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)"
if [[ -z "$release_tag" ]]; then
    echo "Release packaging requires HEAD to have an exact v<major>.<minor>.<patch> tag." >&2
    exit 64
fi
if [[ -n "$(git -C "$repository_root" status --porcelain --untracked-files=all)" ]]; then
    echo "Release packaging requires a clean working tree." >&2
    exit 78
fi

version="${release_tag#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
    echo "Unsupported release tag: $release_tag" >&2
    exit 64
fi

metadata_version="$(plutil -extract CFBundleShortVersionString raw -o - "$repository_root/Support/Info.plist" 2>/dev/null || true)"
if [[ "$metadata_version" != "$version" ]]; then
    echo "Support/Info.plist is $metadata_version, but release tag is $version." >&2
    exit 65
fi

# This is the release-only packaging entry point. build-app.sh stamps the
# resulting arm64 bundle as `release`.
bash "$repository_root/scripts/build-app.sh" release

archive="$repository_root/Warren-$version.zip"
rm -f "$archive"
ditto -c -k --keepParent "$repository_root/Warren.app" "$archive"

checksum="$archive.sha256"
archive_name="$(basename "$archive")"
checksum_name="$(basename "$checksum")"
if command -v shasum >/dev/null 2>&1; then
    (cd "$repository_root" && shasum -a 256 "$archive_name" > "$checksum_name")
else
    (cd "$repository_root" && sha256sum "$archive_name" > "$checksum_name")
fi

echo "Packaged $archive"
echo "Checksum $checksum"
