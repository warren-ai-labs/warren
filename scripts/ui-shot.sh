#!/usr/bin/env bash
# Render the production desktop tree to PNG files without building or installing
# the app.
#
# The tree is mounted in an offscreen hosting view that is never shown, never
# made key, and never ordered in front, so this does not take focus from
# whatever the user is doing. `UIProbe` stays non-visual on purpose; this is the
# visual tool beside it.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="${WARREN_SHOT_DIR:-/tmp/warren-observation/ui-shot}"

for appearance in dark light; do
    swift run --package-path "$repository_root" UIShot \
        --appearance "$appearance" \
        --width "${WARREN_SHOT_WIDTH:-1440}" \
        --height "${WARREN_SHOT_HEIGHT:-900}" \
        --out "$out_dir/$appearance.png"
done

echo
echo "Shots written to $out_dir"
