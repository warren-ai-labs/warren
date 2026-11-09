#!/usr/bin/env bash
# Builds the Web client and deploys it to app.warrenai.xyz (Web/wrangler.toml).
# The deployed copy is marked as a release build and carries headers that keep
# the page, which holds remote connect codes, out of frames and referrers.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
web_root="$repository_root/Web"
deploy_root="$web_root/.deploy"
wrangler="$repository_root/Onboarding/node_modules/.bin/wrangler"

if [[ ! -x "$wrangler" ]]; then
    echo "wrangler is missing; run 'npm --prefix Onboarding install' first" >&2
    exit 1
fi

bash "$repository_root/scripts/prepare-web.sh"
npm --prefix "$web_root" run build

/bin/rm -rf "$deploy_root"
cp -R "$web_root/dist" "$deploy_root"
printf 'release\n' > "$deploy_root/build-variant.txt"
cat > "$deploy_root/_headers" <<'HEADERS'
/*
  Referrer-Policy: no-referrer
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Content-Security-Policy: frame-ancestors 'none'
HEADERS

cd "$web_root"
"$wrangler" deploy --config "$web_root/wrangler.toml" "$@"
