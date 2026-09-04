#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/install-ios.sh [HOST] [options]
       mise run ios:install -- [HOST] [options]

Build WarrenIOSApp for a connected iPhone and install it via devicectl.

HOST formats:
  192.168.1.117          -> http://192.168.1.117:8789
  192.168.1.117:8789     -> http://192.168.1.117:8789
  http://192.168.1.117:8789 -> as-is

Options:
  --host <ip|url>        LAN host/IP or full URL (env: WARREN_IOS_HOST)
  --port <port>          Port when HOST is a bare IP (default: 8789)
  --device <udid>        Target device UDID (env: WARREN_IOS_DEVICE)
                         Default: first connected iPhone via devicectl
  --team <team-id>       Apple Development Team ID (env: DEVELOPMENT_TEAM)
                         Default: 2PX99VFWSU
  --token <token>        Warren host token (env: WARREN_TEST_TOKEN)
                         Default: reads ~/.warren/token
  --no-launch            Build + install only, do not attempt to launch
  -h, --help             Show this help

Environment:
  WARREN_IOS_HOST        Same as --host (or WARREN_IOS_HOST_URL for full URL)
  WARREN_IOS_DEVICE      Same as --device
  WARREN_IOS_HOST_URL    Full URL override, takes precedence over HOST+PORT

Examples:
  mise run ios:install -- 192.168.1.117
  WARREN_IOS_HOST=192.168.1.50 mise run ios:install
  mise run ios:install -- --host http://192.168.1.117:8789 --device 00008150-000E40981140401C
USAGE
}

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="$repository_root/Packages/WarrenIOS/WarrenIOS.xcodeproj"
scheme="WarrenIOSApp"
bundle_id="2PX99VFWSU.WarrenIOSDevice"

host=""
host_url_env="${WARREN_IOS_HOST_URL:-}"
host_env="${WARREN_IOS_HOST:-}"
device="${WARREN_IOS_DEVICE:-}"
port="8789"
team="${DEVELOPMENT_TEAM:-2PX99VFWSU}"
token="${WARREN_TEST_TOKEN:-}"
launch_after_install=true

# Collect positional host and flags.
positional_host=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --host) host="$2"; shift 2 ;;
        --port) port="$2"; shift 2 ;;
        --device|--udid) device="$2"; shift 2 ;;
        --team) team="$2"; shift 2 ;;
        --token) token="$2"; shift 2 ;;
        --no-launch) launch_after_install=false; shift ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) if [[ -z "$positional_host" ]]; then positional_host="$1"; shift; else echo "Unexpected positional argument: $1" >&2; usage >&2; exit 2; fi ;;
    esac
done
# Any remaining args after -- are treated as extra positional (only first is host).
if [[ $# -gt 0 && -z "$positional_host" ]]; then
    positional_host="$1"
fi
if [[ -n "$positional_host" && -z "$host" ]]; then
    host="$positional_host"
fi
if [[ -z "$host" ]]; then
    host="$host_env"
fi
# WARREN_IOS_HOST_URL as full URL takes precedence – treat as host when host still empty.
if [[ -z "$host" && -n "$host_url_env" ]]; then
    host="$host_url_env"
fi

# Auto-detect LAN IP when no host supplied.
auto_detect_host_ip() {
    local ip=""
    # Preferred: default route interface's address (works on Wi-Fi/Ethernet).
    local iface
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [[ -n "$iface" ]]; then
        ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    fi
    if [[ -z "$ip" ]]; then
        for cand in en0 en1 en2 en3; do
            ip="$(ipconfig getifaddr "$cand" 2>/dev/null || true)"
            [[ -n "$ip" ]] && break
        done
    fi
    if [[ -z "$ip" ]]; then
        ip="$(ifconfig 2>/dev/null | awk '/inet 192\.168/{print $2; exit}')"
    fi
    printf '%s' "$ip"
}

if [[ -z "$host" ]]; then
    host="$(auto_detect_host_ip)"
    if [[ -z "$host" ]]; then
        echo "No HOST supplied and auto-detection failed." >&2
        echo "Pass your Mac LAN IP, e.g.:" >&2
        echo "  mise run ios:install -- 192.168.1.117" >&2
        echo "  WARREN_IOS_HOST=192.168.1.117 mise run ios:install" >&2
        exit 2
    fi
    echo "Auto-detected LAN host: $host"
fi

# Normalize to full URL.
host_url=""
if [[ "$host" == http://* || "$host" == https://* ]]; then
    host_url="$host"
elif [[ "$host" == *:* ]]; then
    # Already contains :port
    host_url="http://$host"
else
    host_url="http://$host:$port"
fi
# Explicit WARREN_IOS_HOST_URL overrides the derived URL.
if [[ -n "$host_url_env" && "$host_url_env" == http* ]]; then
    host_url="$host_url_env"
fi

# Resolve token.
if [[ -z "$token" ]]; then
    token_file="$HOME/.warren/token"
    if [[ -f "$token_file" ]]; then
        token="$(tr -d '[:space:]' < "$token_file")"
    fi
fi
if [[ -z "$token" ]]; then
    echo "No Warren token found." >&2
    echo "Start Warren once (mise run dev) to create ~/.warren/token, or pass --token / WARREN_TEST_TOKEN." >&2
    exit 2
fi

# Resolve device UDID.
if [[ -z "$device" ]]; then
    # Try devicectl JSON (CoreDevice) – pick first connected physical device.
    if command -v xcrun >/dev/null 2>&1; then
        tmp_json="$(mktemp -t warren-ios-device.XXXXXX.json)"
        if xcrun devicectl list devices --json-output "$tmp_json" >/dev/null 2>&1; then
            device="$(python3 -c "
import json, re
p='$tmp_json'
try:
    d=json.load(open(p))
    for dev in d.get('result',{}).get('devices',[]):
        # hardwareProperties may contain udid/serialNumber/ECID
        hp=dev.get('hardwareProperties',{}) or {}
        if hp.get('platform') not in (None, 'iOS'):
            continue
        for k in ('udid', 'serialNumber'):
            v=hp.get(k)
            if isinstance(v,str) and re.match(r'^[0-9A-F-]+$', v):
                print(v); raise SystemExit(0)
        # Also try identifier field (CoreDevice UUID)
        v=dev.get('identifier')
        if isinstance(v,str) and re.match(r'^[0-9A-F-]+$', v):
            print(v); raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    pass
" 2>/dev/null)"
        fi
        rm -f "$tmp_json" 2>/dev/null || true
    fi
    if [[ -z "$device" ]]; then
        # Fallback: xctrace list devices – parse the classic UDID.
        device="$(xcrun xctrace list devices 2>&1 | sed -nE '/iPhone \(/s/.*\(([0-9A-F-]+)\).*/\1/p' | head -n 1)"
        if [[ -z "$device" ]]; then
            device="$(xcrun xctrace list devices 2>&1 | grep -E 'iPhone \(' | head -1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')"
        fi
    fi
    if [[ -z "$device" ]]; then
        echo "Could not auto-detect a connected iPhone." >&2
        echo "Pass --device <udid> or set WARREN_IOS_DEVICE after pairing the device." >&2
        exit 2
    fi
fi

# Verify team cert exists when possible, or auto-detect if default team is missing.
if ! security find-identity -v -p codesigning 2>&1 | grep -q "$team"; then
    detected_team="$(security find-identity -v -p codesigning 2>&1 | sed -nE 's/.*Apple Development:.*\(([A-Z0-9]{10})\).*/\1/p' | head -n 1)"
    if [[ -n "$detected_team" ]]; then
        echo "Default team $team not found; using keychain Apple Development team: $detected_team"
        team="$detected_team"
    else
        echo "Warning: Team $team not found in keychain identities; build may fail. Available:" >&2
        security find-identity -v -p codesigning 2>&1 | head -n 20 >&2 || true
    fi
fi

echo "==> Warren iOS install"
echo "    Host URL : $host_url"
echo "    Device   : $device"
echo "    Team     : $team"
echo "    Token    : [provided] (from \$HOME/.warren/token or --token)"
echo "    Project  : $project_path"

# Ensure xcodeproj reflects project.yml (WARREN_IOS_HOST_URL key).
if ! grep -q "WARREN_IOS_HOST_URL" "$project_path/project.pbxproj" 2>/dev/null; then
    if command -v xcodegen >/dev/null 2>&1; then
        echo "Regenerating Xcode project via xcodegen..."
        xcodegen generate --spec "$repository_root/Packages/WarrenIOS/project.yml" --project "$repository_root/Packages/WarrenIOS" 2>&1 | sed 's/^/    /'
    fi
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun not found; install Xcode command line tools." >&2
    exit 1
fi

echo "==> Building WarrenIOSApp (Debug) for device..."
if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild \
        -project "$project_path" \
        -scheme "$scheme" \
        -destination "id=$device" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        -skipPackagePluginValidation \
        build \
        DEVELOPMENT_TEAM="$team" \
        WARREN_TEST_TOKEN="$token" \
        WARREN_IOS_HOST_URL="$host_url" \
        2>&1 | tee /tmp/warren-ios-build.log | xcbeautify
    build_status=${PIPESTATUS[0]}
    set +o pipefail
    if [[ $build_status -ne 0 ]]; then
        echo "Build failed (see /tmp/warren-ios-build.log)" >&2
        tail -n 200 /tmp/warren-ios-build.log >&2 || true
        exit $build_status
    fi
else
    xcodebuild \
        -project "$project_path" \
        -scheme "$scheme" \
        -destination "id=$device" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        -skipPackagePluginValidation \
        build \
        DEVELOPMENT_TEAM="$team" \
        WARREN_TEST_TOKEN="$token" \
        WARREN_IOS_HOST_URL="$host_url" \
        2>&1 | tee /tmp/warren-ios-build.log
    build_status=${PIPESTATUS[0]}
    if [[ $build_status -ne 0 ]]; then
        exit $build_status
    fi
fi

# Locate the built app.
app_path=""
# Prefer the build settings location.
build_dir="$(xcodebuild -project "$project_path" -scheme "$scheme" -destination "id=$device" -showBuildSettings 2>/dev/null | awk -F' = ' '/CONFIGURATION_BUILD_DIR/ {print $2; exit}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -n "$build_dir" && -d "$build_dir/WarrenIOSApp.app" ]]; then
    app_path="$build_dir/WarrenIOSApp.app"
fi
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
    app_path="$(ls -dt ~/Library/Developer/Xcode/DerivedData/WarrenIOS-*/Build/Products/Debug-iphoneos/WarrenIOSApp.app 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$app_path" || ! -d "$app_path" ]]; then
    echo "Build succeeded but WarrenIOSApp.app not found." >&2
    echo "Checked: $build_dir and DerivedData glob. See /tmp/warren-ios-build.log" >&2
    exit 1
fi

echo "Built: $app_path"
# Confirm the baked endpoint without echoing the development credential. The
# token is intentionally present in the signed debug bundle for this local
# install flow, but it must never land in a terminal transcript or CI log.
plutil -p "$app_path/Info.plist" 2>&1 \
    | grep -E "WarrenDevelopment|CFBundleIdentifier" \
    | sed -E 's/(WarrenDevelopmentToken" => ")[^"]+/\1[redacted]/' \
    | sed 's/^/    /' || true
codesign -dvvv "$app_path" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" | sed 's/^/    /' || true

echo "==> Installing to device $device..."
set -x
xcrun devicectl device install app --device "$device" "$app_path" 2>&1 | tee /tmp/warren-ios-install.log | tail -n 50
set +x
if ! grep -q "App installed" /tmp/warren-ios-install.log 2>/dev/null; then
    # devicectl exits 0 even on some failures; check log
    if ! grep -q "bundleID: $bundle_id" /tmp/warren-ios-install.log 2>/dev/null; then
        echo "Install may have failed; check /tmp/warren-ios-install.log" >&2
        cat /tmp/warren-ios-install.log >&2 || true
        exit 1
    fi
fi
echo "Install finished."

if [[ "$launch_after_install" == true ]]; then
    echo "==> Launching $bundle_id on device..."
    launch_log="/tmp/warren-ios-launch.log"
    if xcrun devicectl device process launch --device "$device" --json-output "$launch_log" "$bundle_id" 2>&1 | tee -a "$launch_log.txt" | tail -n 30; then
        echo "Launch requested. If the screen is still dark, unlock the iPhone and tap Warren."
    else
        if grep -q "Locked" "$launch_log" 2>/dev/null || grep -q "Locked" "$launch_log.txt" 2>/dev/null; then
            echo "" >&2
            echo "Device is locked – unlock your iPhone (Face ID / passcode) and tap the Warren icon to launch." >&2
            echo "Or unlock then run:" >&2
            echo "  xcrun devicectl device process launch --device $device $bundle_id" >&2
        else
            echo "Launch failed; app is still installed – tap Warren on the Home Screen." >&2
            echo "Details: $launch_log" >&2
            python3 -m json.tool "$launch_log" 2>&1 | tail -n 80 >&2 || cat "$launch_log" >&2 || true
        fi
    fi
fi

echo ""
echo "Done. Host URL baked into build: $host_url"
echo "Tip: re-run with a different LAN IP any time, e.g.  mise run ios:install -- 192.168.1.50"
