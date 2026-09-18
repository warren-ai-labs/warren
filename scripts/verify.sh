#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

run_package_tests() {
    local package="$1"
    local package_path="$repository_root/Packages/$package"
    local log
    log="$(mktemp -t "warren-${package}-test.XXXXXX")"
    if swift test --package-path "$package_path" 2>&1 | tee "$log"; then
        rm -f "$log"
        return 0
    fi
    local status="${PIPESTATUS[0]}"
    if rg -q 'unexpected signal code 4' "$log"; then
        echo "==> stale SwiftPM ABI cache detected for $package; clean rebuild once"
        swift package --package-path "$package_path" clean
        rm -f "$log"
        swift test --package-path "$package_path"
        return
    fi
    rm -f "$log"
    return "$status"
}

echo "==> swift build"
bash "$repository_root/scripts/prepare-web.sh"
npm --prefix "$repository_root/Web" run check
swift build --package-path "$repository_root"

echo "==> relay control plane"
(cd "$repository_root" && bash -n scripts/relay-dev.sh && go vet ./RelayService/... && go test -race ./RelayService/...)

echo "==> headless daemon and CLI"
(cd "$repository_root" && go vet ./Headless/... && go test -race ./Headless/...)

for package in \
    Domain Protocol StateStore ClientCore Transport \
    TerminalRenderer DesignSystem Desktop WarrenIOS \
    GhosttyAdapter Observation; do
    echo "==> swift test $package"
    run_package_tests "$package"
done

echo "==> non-visual semantic UI acceptance"
WARREN_ARTIFACT_DIR="${WARREN_ARTIFACT_DIR:-/tmp/warren-observation/ui-probe}" \
    swift run --package-path "$repository_root" UIProbe

echo "==> headless terminal color semantics"
WARREN_ARTIFACT_DIR="${WARREN_TERMINAL_ARTIFACT_DIR:-/tmp/warren-observation/terminal-probe}" \
    swift run --package-path "$repository_root" TerminalProbe

echo "==> build app"
WARREN_SKIP_WEB_BUILD=1 bash "$repository_root/scripts/build-app.sh" debug

echo "All checks passed."
