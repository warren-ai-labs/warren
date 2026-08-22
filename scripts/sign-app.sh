#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: scripts/sign-app.sh <Warren.app>

Sign a Warren app bundle with a stable macOS code-signing identity.

Set WARREN_CODESIGN_IDENTITY to select a certificate or SHA-1 hash explicitly.
If no identity is available, set WARREN_ALLOW_ADHOC_SIGNING=1 only for
temporary local development builds; ad-hoc signatures must not be released.
EOF
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Warren app signing is supported only on macOS." >&2
    exit 69
fi

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

app_path="$1"
if [[ ! -d "$app_path/Contents" || ! -f "$app_path/Contents/Info.plist" ]]; then
    echo "Not a macOS app bundle: $app_path" >&2
    exit 64
fi

identity_candidates() {
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
        /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) [0-9A-Fa-f]+ "([^"]+)".*$/\1/p'
}

select_identity() {
    local requested_identity="${WARREN_CODESIGN_IDENTITY:-}"
    if [[ -n "$requested_identity" ]]; then
        printf '%s\n' "$requested_identity"
        return 0
    fi

    local candidates identity prefix
    candidates="$(identity_candidates || true)"
    for prefix in "Developer ID Application:" "Apple Development:" "Mac Development:"; do
        while IFS= read -r identity; do
            [[ -n "$identity" ]] || continue
            if [[ "$identity" == "$prefix"* ]]; then
                printf '%s\n' "$identity"
                return 0
            fi
        done <<< "$candidates"
    done

    return 1
}

if ! signing_identity="$(select_identity)"; then
    if [[ "${WARREN_ALLOW_ADHOC_SIGNING:-0}" == "1" ]]; then
        signing_identity="-"
        echo "Warning: using an ad-hoc signature; do not distribute this app." >&2
    else
        cat >&2 <<'EOF'
No stable code-signing identity was found.

Install an Apple Development certificate for local builds or a Developer ID
Application certificate for distribution, then rerun this command. You can
also set WARREN_CODESIGN_IDENTITY to a certificate name or SHA-1 hash.
EOF
        exit 78
    fi
fi

if [[ "$signing_identity" == "-" && "${WARREN_ALLOW_ADHOC_SIGNING:-0}" != "1" ]]; then
    echo "Refusing an ad-hoc identity; set WARREN_ALLOW_ADHOC_SIGNING=1 only for temporary development." >&2
    exit 78
fi

declare -a code_paths=()
while IFS= read -r -d '' candidate; do
    file_description="$(/usr/bin/file -b "$candidate")"
    case "$file_description" in
        *Mach-O*) code_paths+=("$candidate") ;;
    esac
done < <(/usr/bin/find "$app_path/Contents" -type f -print0)

if [[ "${#code_paths[@]}" -eq 0 ]]; then
    echo "No Mach-O code was found in $app_path." >&2
    exit 65
fi

# Sign nested code before the outer bundle so the app's resource seal includes
# the final signatures. Frameworks must be signed before executables that link
# them so codesign can validate the nested dylib. This covers the desktop,
# menu-bar helper, CLI, daemon, and bundled Ghostty library without relying on
# codesign --deep.
for code_path in "${code_paths[@]}"; do
    [[ "$code_path" == */Contents/Frameworks/* ]] || continue
    /usr/bin/codesign --force --sign "$signing_identity" "$code_path"
done
for code_path in "${code_paths[@]}"; do
    [[ "$code_path" == */Contents/Frameworks/* ]] && continue
    /usr/bin/codesign --force --sign "$signing_identity" "$code_path"
done
/usr/bin/codesign --force --sign "$signing_identity" "$app_path"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

signature_details="$(/usr/bin/codesign -dvv "$app_path" 2>&1)"
team_identifier="$(printf '%s\n' "$signature_details" | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
if [[ "$signing_identity" != "-" && ( -z "$team_identifier" || "$team_identifier" == "not set" ) ]]; then
    echo "Stable signing failed: the app has no TeamIdentifier." >&2
    exit 65
fi

echo "Signed $app_path"
echo "Identity: $signing_identity"
if [[ -n "$team_identifier" ]]; then
    echo "TeamIdentifier: $team_identifier"
fi
