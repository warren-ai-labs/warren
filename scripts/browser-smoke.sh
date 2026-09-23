#!/usr/bin/env bash
# Live end-to-end verification of the Warren Browser (RFC 0022 §10.4).
#
# Unit tests prove the action surface. They do not prove a browser works: they
# run against a stub when Chrome is absent, and a stub cannot tell you whether
# Chromium actually rendered a page. This script runs the real daemon, the real
# CLI, and the real Chrome the user has installed, and prints the artifact a
# reviewer reads.
#
# It needs a display-less Chrome, so it launches the browser headless. That is
# the one place it differs from what the Desktop does, and it is why this is a
# script rather than a test: CI has neither a display nor a browser.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/warren-browser-smoke.XXXXXX")"
daemon_pid=""

cleanup() {
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

step() { echo; echo "==> $*"; }

# ---------------------------------------------------------------- build

step "Building the daemon and CLI"
go build -o "$work/warren-headless" ./Headless/cmd/warren-headless
go build -o "$work/warren" ./Headless/cmd/warren

# ---------------------------------------------------------------- daemon

# A free loopback port, asked of the kernel rather than guessed, so two runs on
# one machine cannot collide.
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
base_url="http://127.0.0.1:$port"

# A throwaway token in a throwaway state directory. Nothing here touches the
# user's real Warren, and the token never leaves this process's environment.
token="$(head -c 32 /dev/urandom | xxd -p | tr -d '\n')"
printf '%s' "$token" > "$work/token"

step "Starting the daemon on $base_url"
"$work/warren-headless" \
  -listen "127.0.0.1:$port" \
  -state "$work/state.json" \
  -token-file "$work/token" \
  -settings-file "$work/settings.json" \
  -log-file "$work/daemon.log" \
  -ghostline-socket "$work/ghostline.sock" \
  -output-dir "$work/output" \
  -worktree-root "$work/worktrees" \
  -lan-https "" \
  > "$work/stdout.log" 2>&1 &
daemon_pid=$!

ready=""
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null "$base_url/healthz"; then ready=1; break; fi
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 0.25
done
[[ -n "$ready" ]] || { tail -20 "$work/daemon.log" "$work/stdout.log" 2>/dev/null; fail "daemon did not become healthy"; }

warren=("$work/warren" --server "$base_url" --token "$token" --json)

# ---------------------------------------------------------------- fixture

step "Writing the page under test"
cat > "$work/page.html" <<'HTML'
<!doctype html>
<html><head><title>Warren Browser Smoke</title></head><body>
<h1 id="heading">Hello Warren</h1>
<form id="form" onsubmit="event.preventDefault();
  document.getElementById('out').textContent =
    'submitted:' + document.getElementById('name').value;">
  <input id="name" type="text" value="">
  <button id="submit" type="submit">Sign in</button>
</form>
<div id="out"></div>
</body></html>
HTML
page_url="file://$work/page.html"

# ---------------------------------------------------------------- scope

# A terminal group rather than a workspace: the browser runtime is scoped like a
# shell is, and a group needs no repository, which keeps this script runnable
# from a checkout with no network.
step "Creating a terminal group"
group_id="$("${warren[@]}" -q terminal-group create --name browser-smoke)"
[[ -n "$group_id" ]] || fail "terminal-group create returned no ID"

# ---------------------------------------------------------------- session

step "Creating a browser session"
session_json="$("${warren[@]}" browser create --group "$group_id" --url "$page_url" --headless)"
session_id="$(printf '%s' "$session_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
[[ -n "$session_id" ]] || fail "browser create returned no ID"
echo "session: $session_id"

# A session that never reaches ready is the failure the rest of this script
# cannot distinguish from any other, so it is checked first and alone.
step "Waiting for the runtime to be ready"
ready_seen=""
for _ in $(seq 1 80); do
  phase="$(printf '%s' "$("${warren[@]}" browser get "$session_id")" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("phase", ""))' 2>/dev/null || true)"
  if [[ "$phase" == "ready" ]]; then ready_seen=1; break; fi
  if [[ "$phase" == "unavailable" || "$phase" == "failed" ]]; then
    fail "browser runtime reported $phase"
  fi
  sleep 0.25
done
[[ -n "$ready_seen" ]] || fail "browser runtime never became ready"

# ---------------------------------------------------------------- drive

step "navigate"
"${warren[@]}" browser action "$session_id" navigate --url "$page_url" --wait-until load \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); print("title:", r.get("title"))'

step "snapshot (interactive only)"
snapshot="$("${warren[@]}" browser action "$session_id" snapshot --interactive)"
python3 - "$snapshot" <<'PY' || exit 1
import json, sys
payload = json.loads(sys.argv[1])
nodes = (payload.get("result") or {}).get("nodes", [])
texts = [n.get("text", "") for n in nodes]
selectors = [n.get("selector", "") for n in nodes]
assert any("Sign in" in t for t in texts), f"no 'Sign in' node in {texts}"
assert any("name" in s for s in selectors), f"no name input in {selectors}"
print(f"{len(nodes)} interactive nodes; found 'Sign in' and the name input")
PY

step "type into the input"
"${warren[@]}" browser action "$session_id" type --selector "#name" --value "warren" --clear

step "click Sign in"
"${warren[@]}" browser action "$session_id" click --text "Sign in"

step "wait for the submitted text"
"${warren[@]}" browser action "$session_id" wait --text "submitted:warren" --timeout 5000

step "evaluate (assert the page state directly)"
"${warren[@]}" browser action "$session_id" evaluate \
  --expression "document.getElementById('out').textContent" \
  | python3 -c 'import json,sys; v=(json.load(sys.stdin).get("result") or {}).get("value",""); assert v=="submitted:warren", v; print("page says:", v)'

# ---------------------------------------------------------------- verify

# The verification path from RFC 0022 §6.4: an agent that can write a file and
# read it spends a tool call instead of context on an image.
step "screenshot --out (the self-verification path)"
shot="$work/verify.png"
"${warren[@]}" browser action "$session_id" screenshot --path "$shot"
[[ -s "$shot" ]] || fail "screenshot file is missing or empty"
python3 - "$shot" <<'PY' || exit 1
import struct, sys
path = sys.argv[1]
with open(path, "rb") as handle:
    header = handle.read(24)
assert header[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
width, height = struct.unpack(">II", header[16:24])
assert width > 0 and height > 0, f"degenerate dimensions {width}x{height}"
import os
print(f"PNG {width}x{height}, {os.path.getsize(path)} bytes")
PY

step "console"
"${warren[@]}" browser action "$session_id" console --limit 5

step "tabs.list"
"${warren[@]}" browser action "$session_id" tabs.list \
  | python3 -c 'import json,sys; t=(json.load(sys.stdin).get("result") or {}).get("tabs",[]); print(f"{len(t)} tab(s)"); assert t, "no tabs reported"'

# ---------------------------------------------------------------- viewer

# The viewer page is part of the runtime, not the client bundle, so it is
# reachable without a client at all. An unauthenticated request proves the page
# is served; the stream behind it is what requires the token.
step "viewer page"
viewer_code="$(curl -s -o "$work/viewer.html" -w '%{http_code}' "$base_url/v1/browser/view?session=$session_id")"
[[ "$viewer_code" == "200" ]] || fail "viewer page returned $viewer_code"
grep -q "Warren Browser" "$work/viewer.html" || fail "viewer page has no title"
echo "GET /v1/browser/view -> 200, $(wc -c < "$work/viewer.html" | tr -d ' ') bytes"

# ---------------------------------------------------------------- close

step "close"
"${warren[@]}" browser close "$session_id" > /dev/null

step "session is gone from the roster"
if "${warren[@]}" -q browser list --group "$group_id" | grep -q "$session_id"; then
  fail "closed browser still listed"
fi
echo "browser list is empty"

echo
echo "Warren Browser smoke passed."
