# Warren Onboarding

The public onboarding site for Warren, served from a Cloudflare Worker.

## Stack

- React + Vite for the front-end
- Cloudflare Worker with static assets for hosting
- `ghostty-web` for an interactive terminal demo (Ghostty's VT parser compiled to WebAssembly)
- Built-in English / Simplified Chinese i18n
- Chinese display type: ZCOOL XiaoWei (站酷小薇) + MiSans (小米)

The Download button resolves the latest GitHub release through the Worker's
`/api/latest-release` endpoint and starts the installer download directly.
The desktop updater uses the same Worker snapshot through
`/api/update/latest`.

The standalone `/changelog` page presents the release history in the same
English / Simplified Chinese interface as the landing page. The Worker reads
released entries from the repository root `CHANGELOG.md` at runtime, caches the
parsed response for five minutes, and serves stale data while refreshing. The
browser also keeps the last successful response locally for offline fallback.

## Local development

Prerequisites:

- Node.js 22 or newer (the checked-in lockfile declares this engine range)
- npm 10 or newer

Install from the lockfile before running a production build. `node_modules/`
is intentionally not committed:

```sh
npm ci
npm run dev        # Vite HMR at http://localhost:5173
```

To preview the exact Cloudflare Worker behavior locally:

```sh
npm run build
npm run preview    # wrangler dev at http://localhost:8787
```

## Deploy

```sh
npx wrangler secret put GITHUB_TOKEN  # optional; run once per environment
npm run deploy
```

The worker name is `warren-onboarding`. Once `warrenai.xyz` is ready on
Cloudflare, uncomment the `routes` block in `wrangler.toml` and deploy again.

Release resolution never sends an unauthenticated GitHub Releases API request.
With `GITHUB_TOKEN`, the Worker uses the authenticated API; otherwise it reads
the public release page and caches the normalized snapshot for five minutes.
See [`docs/update-service.md`](../docs/update-service.md) for the endpoint
contract and operational policy.

## Notes

- The site lives in `Onboarding/` inside the Warren repository. It is
  self-contained and does not touch other source trees.
- `ghostty-web` inlines its WASM bundle, so no extra static asset is needed.
