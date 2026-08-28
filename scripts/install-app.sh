#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repository_root/Warren.app"
install_path="/Applications/Warren.app"
executable_path="$app_path/Contents/MacOS/Warren"
installed_executable_path="$install_path/Contents/MacOS/Warren"
menubar_executable_path="$app_path/Contents/MacOS/WarrenDaemonMenuBar"
installed_menubar_executable_path="$install_path/Contents/MacOS/WarrenDaemonMenuBar"
daemon_executable_path="$app_path/Contents/MacOS/warren-headless"
installed_daemon_executable_path="$install_path/Contents/MacOS/warren-headless"

# macOS pgrep/pkill cannot always see processes whose executable file has
# been replaced while running, so resolve PIDs from `ps` and kill by PID.
pids_for_path() {
    local executable="$1"
    # Match only argument-less invocations (exactly `pid executable`), so the
    # separate Ghostline serve process (started with --ghostline-serve)
    # is never matched or killed.
    # WARNING: never loosen this filter. The ghostline serve process owns the
    # PTY sessions and is designed to survive installs, restarts and updates;
    # killing it takes every running session down with it.
    ps -axo pid=,command= | awk -v exe="$executable" '$2 == exe && NF == 2 { print $1 }'
}

is_running() {
    [[ -n "$(pids_for_path "$executable_path")$(pids_for_path "$installed_executable_path")" ]]
}

is_menubar_running() {
    [[ -n "$(pids_for_path "$menubar_executable_path")$(pids_for_path "$installed_menubar_executable_path")" ]]
}

is_daemon_running() {
    [[ -n "$(pids_for_path "$daemon_executable_path")$(pids_for_path "$installed_daemon_executable_path")" ]]
}

notify_maintenance() {
    local token_file="$HOME/.warren/token"
    [[ -r "$token_file" ]] || return 0
    local token
    token="$(tr -d '[:space:]' < "$token_file")"
    [[ -n "$token" ]] || return 0
    curl -fsS -m 2 -X POST "http://127.0.0.1:8789/v1/maintenance" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{"message":"Installing a new Warren build; the daemon will restart."}' \
        >/dev/null 2>&1 || true
}

initialize_local_endpoint() {
    local endpoint_name="local"
    local endpoint_url="http://127.0.0.1:8789"
    local config_path="$HOME/.warren/config.json"
    local token_path="$HOME/.warren/token"
    local cli="$cli_install_directory/warren"

    if [[ -f "$config_path" ]] && "$cli" --config "$config_path" endpoint list 2>/dev/null | \
        awk -v name="$endpoint_name" '$1 == name || $2 == name { found=1 } END { exit !found }'; then
        echo "Local endpoint '$endpoint_name' already configured"
        return
    fi

    mkdir -p "$(dirname "$config_path")"
    if [[ ! -s "$token_path" ]]; then
        (umask 077; openssl rand -base64 32 | tr -d '\n' > "$token_path")
    fi

    local token
    token="$(tr -d '[:space:]' < "$token_path")"
    if [[ -z "$token" ]]; then
        echo "Could not initialize local endpoint: token is empty at $token_path" >&2
        exit 1
    fi

    "$cli" --config "$config_path" endpoint add "$endpoint_name" \
        --url "$endpoint_url" --token "$token" --use
    echo "Initialized local endpoint '$endpoint_name' at $endpoint_url"
}

force_terminate_pids() {
    local pids="${1:-}"
    local pid
    [[ -z "${pids//[[:space:]]/}" ]] && return 0
    for pid in $pids; do
        kill -TERM "$pid" >/dev/null 2>&1 || true
    done
    for _ in {1..30}; do
        [[ -z "$(ps -p $pids -o pid= 2>/dev/null)" ]] && return 0
        sleep 0.1
    done
    for pid in $pids; do
        kill -KILL "$pid" >/dev/null 2>&1 || true
    done
    for _ in {1..30}; do
        [[ -z "$(ps -p $pids -o pid= 2>/dev/null)" ]] && return 0
        sleep 0.1
    done
    return 1
}

echo "Building Warren.app (release)..."
bash "$repository_root/scripts/build-app.sh" release

# When a forced ghostline handoff is requested, persist a marker that survives
# `open` (which does not propagate the install shell's environment to the
# LS-launched app). The headless daemon checks both the env var and this file
# and clears it after the handoff, so `mise run install` and menubar Restart
# reliably pick up a rebuilt binary even when the version string is unchanged
# (dev hash rebuilds).
force_marker="$HOME/.warren/force-ghostline-handoff"
should_force="false"
_force_value="$(printf '%s' "${WARREN_GHOSTLINE_FORCE_HANDOFF:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [[ -n "$_force_value" && "$_force_value" != "0" && "$_force_value" != "false" ]]; then
    should_force="true"
else
    _force_value="$(printf '%s' "${WARREN_FORCE_HANDOFF:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [[ -n "$_force_value" && "$_force_value" != "0" && "$_force_value" != "false" ]]; then
        should_force="true"
    fi
fi
if [[ "$should_force" == "true" ]]; then
    mkdir -p "$(dirname "$force_marker")"
    : > "$force_marker"
    chmod 600 "$force_marker" 2>/dev/null || true
fi

# Tell connected Desktop/Web clients the daemon is about to restart so they
# show an update state instead of a misleading connection error. Best-effort:
# old daemons without the endpoint simply restart without the notice.
notify_maintenance

relaunch_after_install=false
if is_running; then
    relaunch_after_install=true
    osascript -e 'tell application id "com.abcdlsj.warren" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do
        is_running || break
        sleep 0.1
    done
fi

if is_running; then
    force_terminate_pids "$(pids_for_path "$executable_path") $(pids_for_path "$installed_executable_path")" || true
fi

if is_menubar_running; then
    force_terminate_pids "$(pids_for_path "$menubar_executable_path") $(pids_for_path "$installed_menubar_executable_path")" || true
fi

# The daemon is deliberately independent during normal Desktop shutdown, but
# an app update must replace its executable too. Ghostline PTYs remain owned by
# the separate serve process, and the new menu-bar process starts the freshly
# installed control-plane daemon.
# Only the control-plane daemon may be terminated here. The ghostline serve
# process (warren-headless --ghostline-serve ...) is a separate long-lived
# session owner and must NEVER be killed during install/restart/update; the
# new daemon reuses or adopts it so sessions keep running.
if is_daemon_running; then
    force_terminate_pids "$(pids_for_path "$daemon_executable_path") $(pids_for_path "$installed_daemon_executable_path")" || true
fi

if is_running; then
    echo "Warren did not terminate before installation." >&2
    exit 1
fi

if is_menubar_running; then
    echo "Warren daemon menubar did not terminate before installation." >&2
    exit 1
fi

if is_daemon_running; then
    echo "Warren headless daemon did not terminate before installation." >&2
    exit 1
fi

echo "Installing to $install_path..."
rm -rf "$install_path"
ditto "$app_path" "$install_path"
cli_install_directory="$HOME/.local/bin"
mkdir -p "$cli_install_directory"
install -m 755 "$app_path/Contents/MacOS/warren-cli" "$cli_install_directory/warren"
install -m 755 "$app_path/Contents/MacOS/warren-headless" "$cli_install_directory/warren-headless"
echo "Installed $install_path"
echo "Installed CLI tools to $cli_install_directory"
echo "Initializing local CLI endpoint..."
initialize_local_endpoint
if [[ "$relaunch_after_install" == true ]]; then
    open "$install_path"
    echo "Relaunched $install_path"
fi
