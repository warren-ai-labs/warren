#!/usr/bin/env bash
# Removes stale Swift Package directories under Packages/ that have no
# Package.swift. These are local SwiftPM build leftovers (typically only a
# .build/ subdirectory) that survive across worktrees because .build/ is
# git-ignored. Real packages are always identifiable by their Package.swift.

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
packages_directory="$repository_root/Packages"

if [[ ! -d "$packages_directory" ]]; then
    exit 0
fi

removed=()
for candidate in "$packages_directory"/*/; do
    [[ -d "$candidate" ]] || continue
    name="$(basename "$candidate")"
    if [[ -f "$candidate/Package.swift" ]]; then
        continue
    fi
    # Track-only files in git would be in HEAD. We must scope the path under
    # Packages/; using the bare basename would let nested tracked packages
    # like Packages/Vendor/GhosttyEmbedding slip through the check.
    if git -C "$repository_root" ls-tree -r HEAD -- "Packages/$name" 2>/dev/null | grep -q .; then
        echo "skip: Packages/$name has tracked files in HEAD but no Package.swift (manual review needed)" >&2
        continue
    fi
    rm -rf "$candidate"
    removed+=("$name")
done

if [[ ${#removed[@]} -eq 0 ]]; then
    exit 0
fi

printf 'removed stale package directories: %s\n' "${removed[*]}"
