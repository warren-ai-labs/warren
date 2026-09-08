# Warren Update Service

The desktop updater reads release metadata from the Warren Cloudflare Worker,
not directly from the GitHub Releases API:

```text
Warren.app -> https://warrenai.xyz/api/update/latest -> Cloudflare Worker
                                                    -> GitHub release page/API
```

## Endpoint contract

`GET https://warrenai.xyz/api/update/latest` returns a read-only JSON document
with both the onboarding fields and the GitHub-compatible fields consumed by
the desktop updater:

```json
{
  "tag": "v0.5.1",
  "tag_name": "v0.5.1",
  "html_url": "https://github.com/warren-ai-labs/warren/releases/tag/v0.5.1",
  "assets": [
    {
      "name": "Warren-0.5.1.zip",
      "browser_download_url": "https://github.com/warren-ai-labs/warren/releases/download/v0.5.1/Warren-0.5.1.zip",
      "size": 20847018
    }
  ],
  "name": "Warren-0.5.1.zip",
  "size": 20847018,
  "url": "https://github.com/warren-ai-labs/warren/releases/download/v0.5.1/Warren-0.5.1.zip"
}
```

The existing `/api/latest-release` onboarding endpoint uses the same response,
so the site and desktop client share one release snapshot without breaking the
download button.

## Rate-limit policy

The Worker must never make an unauthenticated request to the GitHub Releases
API. When the `GITHUB_TOKEN` Worker secret is present, it uses an authenticated
API request. When the secret is absent or rejected, it resolves the latest tag
and archive from the public GitHub release HTML pages instead. This fallback
does not consume the unauthenticated REST API quota.

Both paths are protected by Cloudflare Cache API storage:

- fresh snapshots are served for five minutes;
- stale snapshots are served while one request refreshes them in the
  background;
- a refresh failure does not discard a previously valid snapshot.

The Worker response includes `X-Warren-Release-Source`,
`X-Warren-Release-Cached-At`, and `X-Warren-Release-Stale` for diagnosis. These
headers contain no credentials.

## Deployment

The Worker source and Wrangler configuration live under `Onboarding/`.
Configure the optional token in the Cloudflare account, never in Git:

```sh
cd Onboarding
npx wrangler secret put GITHUB_TOKEN
npm run deploy
```

The HTML resolver keeps the endpoint functional when the secret is not
configured, but the token is recommended for complete release metadata such as
the archive size and release notes.

## Client behavior

`Sources/Warren/WarrenUpdater.swift` points at the Worker endpoint. The app
still applies the existing three-hour automatic-check cadence and always allows
the menu's manual check. Release builds display the `Update` or `Failed`
status beside the traffic-light row; preview builds retain the `BUILD` marker.
