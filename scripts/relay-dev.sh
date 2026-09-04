#!/usr/bin/env bash

set -euo pipefail

command_name="${1:-up}"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
relay_port="${WARREN_RELAY_DEV_PORT:-8080}"
if [[ -n "${WARREN_RELAY_URL:-}" ]]; then
    manages_local_relay=0
    relay_url="${WARREN_RELAY_URL%/}"
    relay_local_url="$relay_url"
    if [[ "$relay_url" != https://* ]]; then
        echo "WARREN_RELAY_URL must use https:// so credentials are never sent in plaintext." >&2
        exit 64
    fi
    relay_identity="$(printf '%s' "$relay_url" | shasum -a 256 | cut -c 1-16)"
    default_state_directory="$HOME/Library/Application Support/Warren/relay-cli/$relay_identity"
else
    manages_local_relay=1
    if [[ ! "$relay_port" =~ ^[0-9]+$ ]] || ((relay_port < 1 || relay_port > 65535)); then
        echo "WARREN_RELAY_DEV_PORT must be an integer from 1 to 65535." >&2
        exit 64
    fi
    # The browser may run on another device. `127.0.0.1` would point back to
    # that device, so local development publishes the Mac's LAN address by
    # default. Override this when the Mac has multiple reachable networks.
    relay_bind_host="${WARREN_RELAY_DEV_BIND_HOST:-0.0.0.0}"
    relay_public_host="${WARREN_RELAY_DEV_HOST:-}"
    if [[ -z "$relay_public_host" ]]; then
        relay_public_host="$(
            interface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
            if [[ -n "$interface" ]]; then
                ipconfig getifaddr "$interface" 2>/dev/null || true
            fi
        )"
    fi
    if [[ -z "$relay_public_host" ]]; then
        echo "Unable to discover the Mac LAN IPv4 address. Set WARREN_RELAY_DEV_HOST, for example 192.168.1.23." >&2
        exit 69
    fi
    relay_url="http://$relay_public_host:$relay_port"
    # Headless stays on loopback; only the browser-facing URL uses the LAN
    # address. This keeps the local connector independent of LAN routing.
    relay_local_url="http://127.0.0.1:$relay_port"
    default_state_directory="$repository_root/.build/relay-dev/$relay_port"
fi
state_directory="${WARREN_RELAY_STATE_DIR:-${WARREN_RELAY_DEV_STATE_DIR:-$default_state_directory}}"
app_executable="$repository_root/Warren.app/Contents/MacOS/Warren"

admin_token_file="$state_directory/admin-token"
signing_key_file="$state_directory/signing-key"
enrollment_key_file="$state_directory/enrollment-key"
enrollment_settings_url_file="$state_directory/enrollment-settings-url"
pid_file="$state_directory/relay.pid"
log_file="$state_directory/relay.log"
registry_file="$state_directory/registry.json"
relay_binary="$state_directory/warren-relay"
daemon_token_file="${WARREN_TOKEN_FILE:-$HOME/.warren/token}"
settings_file="${WARREN_SETTINGS_FILE:-$HOME/.warren/settings.json}"

relay_enrollment_key=""
enrollment_settings_url=""

usage() {
    cat <<'EOF'
Usage: scripts/relay-dev.sh [up|start|pair|status|stop|logs]

  up      Start a local Relay when needed, obtain an enrollment key, launch
          Warren, wait for headless to claim its Host, and pair a client.
  start   Start the Relay without launching or restarting Warren.
  pair    Generate and open another shareable Web/PWA URL.
  status  Show Relay health and the enrolled Host status.
  stop    Stop the local Relay. Warren and its Ghostline sessions keep running.
  logs    Follow the local Relay log.

Set WARREN_RELAY_NO_OPEN=1 to print the Web URL without opening a browser.
For phone access, the local Relay listens on all interfaces and publishes the
Mac LAN address. Set WARREN_RELAY_DEV_HOST when the default route is not the
network reachable by your phone; set WARREN_RELAY_DEV_BIND_HOST to restrict
the bind address.
Set WARREN_RELAY_URL=https://relay.example.com to use a deployed Relay.
Provide WARREN_RELAY_ENROLLMENT_KEY, or provide WARREN_RELAY_ADMIN_TOKEN once
so this helper can create one through /v1/admin/enrollment-keys.
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 69
    }
}

prepare_state() {
    mkdir -p "$state_directory"
    chmod 700 "$state_directory"
}

read_secret() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    <"$path" tr -d '\r\n'
}

write_secret() {
    local path="$1"
    local value="$2"
    mkdir -p "$(dirname "$path")"
    (umask 077 && printf '%s\n' "$value" >"$path")
}

ensure_daemon_token() {
    local token
    token="$(read_secret "$daemon_token_file" 2>/dev/null || true)"
    if [[ -z "$token" ]]; then
        token="$(openssl rand -hex 32)"
        write_secret "$daemon_token_file" "$token"
    fi
}

json_field() {
    local field="$1"
    /usr/bin/python3 -c 'import json,sys; value=json.load(sys.stdin); print(value[sys.argv[1]])' "$field"
}

settings_field() {
    local field="$1"
    /usr/bin/python3 - "$settings_file" "$field" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        value = json.load(handle)
except (FileNotFoundError, OSError, json.JSONDecodeError):
    raise SystemExit(1)
for part in sys.argv[2].split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value[part]
if value is None:
    raise SystemExit(1)
print(value)
PY
}

relay_host_id() {
    settings_field relay.hostID 2>/dev/null || true
}

relay_pid() {
    local value
    value="$(read_secret "$pid_file" 2>/dev/null || true)"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

relay_is_running() {
    local pid
    pid="$(relay_pid)" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [[ "$(ps -p "$pid" -o command= 2>/dev/null || true)" == "$relay_binary" ]]
}

wait_for_health() {
    for _ in {1..100}; do
        if curl --fail --silent --max-time 1 "$relay_local_url/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    echo "Relay did not become healthy. See $log_file" >&2
    return 1
}

start_relay() {
    if [[ "$manages_local_relay" != "1" ]]; then
        prepare_state
        wait_for_health
        return
    fi
    prepare_state
    local admin_token signing_key
    admin_token="$(read_secret "$admin_token_file" 2>/dev/null || true)"
    signing_key="$(read_secret "$signing_key_file" 2>/dev/null || true)"
    if [[ -z "$admin_token" ]]; then
        admin_token="$(openssl rand -hex 32)"
        write_secret "$admin_token_file" "$admin_token"
    fi
    if [[ -z "$signing_key" ]]; then
        signing_key="$(openssl rand -hex 32)"
        write_secret "$signing_key_file" "$signing_key"
    fi
    if relay_is_running; then
        if wait_for_health; then
            return
        fi
        # A process from an older script version may still be bound to
        # 127.0.0.1. It is our exact binary/pid, but not reachable from the
        # newly published LAN URL, so replace it with the current listener.
        local stale_pid
        stale_pid="$(relay_pid)"
        echo "Existing Relay pid $stale_pid is not reachable at $relay_url; restarting it for LAN access." >&2
        kill "$stale_pid" 2>/dev/null || true
        for _ in {1..50}; do
            kill -0 "$stale_pid" 2>/dev/null || break
            sleep 0.1
        done
        rm -f "$pid_file"
    fi
    if /usr/sbin/lsof -nP -iTCP:"$relay_port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "Port $relay_port is already used by another process." >&2
        echo "Set WARREN_RELAY_DEV_PORT to choose another local port." >&2
        exit 1
    fi
    env -u GOROOT -u GOBIN go build -o "$relay_binary" ./RelayService/cmd/warren-relay
    # Detach from the mise/terminal process group so the Relay remains alive
    # after `relay:dev` finishes and can serve a phone browser.
    WARREN_RELAY_LISTEN="$relay_bind_host:$relay_port" \
        WARREN_RELAY_PUBLIC_URL="$relay_url" \
        WARREN_RELAY_ALLOWED_ORIGIN="$relay_url" \
        WARREN_RELAY_ADMIN_TOKEN="$admin_token" \
        WARREN_RELAY_SIGNING_KEY="$signing_key" \
        WARREN_RELAY_DATA="$registry_file" \
        nohup "$relay_binary" </dev/null >>"$log_file" 2>&1 &
    local pid=$!
    write_secret "$pid_file" "$pid"
    if ! wait_for_health; then
        kill "$pid" 2>/dev/null || true
        return 1
    fi
}

build_settings_url() {
    /usr/bin/python3 - "$relay_url" "$relay_enrollment_key" <<'PY'
from urllib.parse import urlencode
import sys

print("warren://settings?" + urlencode({
    "section": "relay",
    "relayUrl": sys.argv[1],
    "enrollmentKey": sys.argv[2],
}))
PY
}

ensure_enrollment_key() {
    prepare_state
    relay_enrollment_key="${WARREN_RELAY_ENROLLMENT_KEY:-}"
    if [[ -z "$relay_enrollment_key" && "${WARREN_RELAY_NEW_ENROLLMENT_KEY:-0}" != "1" ]]; then
        relay_enrollment_key="$(read_secret "$enrollment_key_file" 2>/dev/null || true)"
    fi
    if [[ -z "$relay_enrollment_key" ]]; then
        local admin_token response
        if [[ "$manages_local_relay" == "1" ]]; then
            admin_token="$(read_secret "$admin_token_file" 2>/dev/null || true)"
        else
            admin_token="${WARREN_RELAY_ADMIN_TOKEN:-}"
        fi
        if [[ -z "$admin_token" ]]; then
            echo "No Relay enrollment key is configured." >&2
            echo "Set WARREN_RELAY_ENROLLMENT_KEY, or set WARREN_RELAY_ADMIN_TOKEN once to create one." >&2
            exit 64
        fi
        response="$(curl --fail --silent --show-error \
            -X POST "$relay_local_url/v1/admin/enrollment-keys" \
            -H "Authorization: Bearer $admin_token" \
            -H 'Content-Type: application/json' \
            -d '{"count":1}')"
        relay_enrollment_key="$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["keys"][0]["key"])')"
        write_secret "$enrollment_key_file" "$relay_enrollment_key"
        enrollment_settings_url="$(printf '%s' "$response" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["keys"][0]["settings_url"])')"
        write_secret "$enrollment_settings_url_file" "$enrollment_settings_url"
    fi
    if [[ -z "$relay_enrollment_key" ]]; then
        echo "Relay enrollment key is empty." >&2
        exit 64
    fi
    if [[ -z "$enrollment_settings_url" ]]; then
        enrollment_settings_url="$(read_secret "$enrollment_settings_url_file" 2>/dev/null || true)"
    fi
    if [[ -z "$enrollment_settings_url" ]]; then
        enrollment_settings_url="$(build_settings_url)"
    fi
}

launch_warren() {
    ensure_daemon_token
    bash "$repository_root/scripts/build-app.sh" debug

    if pgrep -f "$app_executable$" >/dev/null 2>&1; then
        osascript -e 'tell application id "com.abcdlsj.warren" to quit' >/dev/null 2>&1 || true
        for _ in {1..50}; do
            pgrep -f "$app_executable$" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi
    if pgrep -f "$app_executable$" >/dev/null 2>&1; then
        # `open`/AppleScript can fail when a previous debug app is hung or was
        # launched from a dead GUI session. This is the exact Warren binary we
        # own, so terminate it before importing the new Relay key.
        while read -r stale_pid; do
            [[ "$stale_pid" =~ ^[0-9]+$ ]] || continue
            kill -TERM "$stale_pid" 2>/dev/null || true
        done < <(pgrep -f "$app_executable$" || true)
        for _ in {1..50}; do
            pgrep -f "$app_executable$" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi
    if pgrep -f "$app_executable$" >/dev/null 2>&1; then
        while read -r stale_pid; do
            [[ "$stale_pid" =~ ^[0-9]+$ ]] || continue
            kill -KILL "$stale_pid" 2>/dev/null || true
        done < <(pgrep -f "$app_executable$" || true)
        for _ in {1..50}; do
            pgrep -f "$app_executable$" >/dev/null 2>&1 || break
            sleep 0.1
        done
    fi
    if pgrep -f "$app_executable$" >/dev/null 2>&1; then
        echo "Warren is already running and could not be restarted for Relay key import." >&2
        exit 1
    fi
    open --env "WARREN_RELAY_URL=$relay_local_url" \
        --env "WARREN_RELAY_ENROLLMENT_KEY=$relay_enrollment_key" \
        --env "WARREN_SETTINGS_FILE=$settings_file" \
        --env "WARREN_TOKEN_FILE=$daemon_token_file" \
        "$repository_root/Warren.app"
}

host_is_online() {
    local host_id="$1"
    local host_token="$2"
    local response
    response="$(curl --silent --max-time 1 \
        "$relay_local_url/v1/hosts/$host_id" \
        -H "Authorization: Bearer $host_token" 2>/dev/null || true)"
    [[ -n "$response" ]] && [[ "$(printf '%s' "$response" | json_field online 2>/dev/null || true)" == "True" ]]
}

wait_for_host() {
    local attempts="${1:-150}"
    local host_id host_token
    for ((attempt = 0; attempt < attempts; attempt++)); do
        host_id="$(relay_host_id)"
        host_token="$(read_secret "$daemon_token_file" 2>/dev/null || true)"
        if [[ -n "$host_id" && -n "$host_token" ]] && host_is_online "$host_id" "$host_token"; then
            return 0
        fi
        if ((attempt % 10 == 0)) && ! pgrep -f "$app_executable$" >/dev/null 2>&1; then
            echo "Warren exited before headless connected to Relay. See Console logs and $log_file" >&2
            return 1
        fi
        sleep 0.1
    done
    echo "Warren did not connect to Relay. See $log_file" >&2
    return 1
}

pair_host() {
    local host_id host_token pairing_response pairing_code paired_response web_url
    host_id="$(relay_host_id)"
    host_token="$(read_secret "$daemon_token_file" 2>/dev/null || true)"
    if [[ -z "$host_id" || -z "$host_token" ]]; then
        echo "No enrolled Host is available. Run relay:dev (or relay:connect) first." >&2
        exit 64
    fi
    pairing_response="$(curl --fail --silent --show-error \
        -X POST "$relay_url/v1/hosts/$host_id/pairing" \
        -H "Authorization: Bearer $host_token")"
    pairing_code="$(printf '%s' "$pairing_response" | json_field pairing_code)"
    paired_response="$(curl --fail --silent --show-error \
        -X POST "$relay_url/v1/pair" \
        -H 'Content-Type: application/json' \
        -d "{\"host_id\":\"$host_id\",\"pairing_code\":\"$pairing_code\"}")"
    web_url="$(printf '%s' "$paired_response" | json_field web_url)"
    echo "Warren Remote is ready:"
    echo "$web_url"
    if [[ "$manages_local_relay" == "1" ]]; then
        echo "Keep the phone and Mac on the same network (Mac: ${relay_public_host}:${relay_port})."
        echo "If the URL is unreachable, check that the macOS firewall allows Warren Relay inbound connections."
    fi
    if [[ "${WARREN_RELAY_NO_OPEN:-0}" != "1" ]]; then
        open "$web_url"
    fi
}

show_status() {
    wait_for_health
    local host_id host_token
    host_id="$(relay_host_id)"
    host_token="$(read_secret "$daemon_token_file" 2>/dev/null || true)"
    echo "Relay: healthy at $relay_url"
    if [[ -n "$host_id" && -n "$host_token" ]]; then
        curl --fail --silent --show-error \
            "$relay_local_url/v1/hosts/$host_id" \
            -H "Authorization: Bearer $host_token" | /usr/bin/python3 -m json.tool
    else
        echo "Host: not enrolled"
    fi
}

stop_relay() {
    if [[ "$manages_local_relay" != "1" ]]; then
        echo "Refusing to stop externally deployed Relay $relay_url." >&2
        exit 64
    fi
    local pid
    if ! pid="$(relay_pid)" || ! relay_is_running; then
        echo "Relay is not running."
        return
    fi
    kill "$pid"
    for _ in {1..50}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "Relay did not stop cleanly (pid $pid)." >&2
        exit 1
    fi
    echo "Relay stopped. Warren and Ghostline sessions were left running."
}

require_command curl
require_command /usr/bin/python3
require_command openssl
require_command /usr/sbin/lsof
require_command ps
require_command pgrep

case "$command_name" in
    up)
        if [[ "$manages_local_relay" == "1" ]]; then
            require_command go
        fi
        start_relay
        ensure_enrollment_key
        echo "Relay enrollment settings URL (Desktop):"
        echo "$enrollment_settings_url"
        if ! wait_for_host 20 >/dev/null 2>&1; then
            launch_warren
            wait_for_host
        fi
        pair_host
        ;;
    start)
        if [[ "$manages_local_relay" == "1" ]]; then
            require_command go
        fi
        start_relay
        echo "Relay is healthy at $relay_url"
        ;;
    pair)
        pair_host
        ;;
    status)
        show_status
        ;;
    stop)
        stop_relay
        ;;
    logs)
        if [[ "$manages_local_relay" != "1" ]]; then
            echo "External Relay logs are managed by its deployment platform." >&2
            exit 64
        fi
        prepare_state
        touch "$log_file"
        tail -f "$log_file"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
