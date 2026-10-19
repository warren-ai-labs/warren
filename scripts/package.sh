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

# The website downloads the disk image; the in-app updater installs the zip.
disk_image="$repository_root/Warren-$version.dmg"
bash "$repository_root/scripts/build-dmg.sh" "$repository_root/Warren.app" "$disk_image"

write_checksum() {
    local artifact_name
    artifact_name="$(basename "$1")"
    if command -v shasum >/dev/null 2>&1; then
        (cd "$repository_root" && shasum -a 256 "$artifact_name" > "$artifact_name.sha256")
    else
        (cd "$repository_root" && sha256sum "$artifact_name" > "$artifact_name.sha256")
    fi
}
write_checksum "$archive"
write_checksum "$disk_image"

echo "Packaged $archive"
echo "Packaged $disk_image"
echo "Checksums $archive.sha256 $disk_image.sha256"
