# Warren Title Service

Lightweight Cloudflare Worker that generates concise coding-session titles for Warren and Kip using Cloudflare Workers AI.

## Endpoint

- `GET /health` — Health check and public quota metadata.
- `POST /v1/title` — Generate a single-line session title.
  - Required header: `X-Device-Id` (8–128 characters `[A-Za-z0-9._:-]`).
  - Optional header: `X-App` (`warren` or `kip`).
  - Optional header: `Authorization: Bearer <OWNER_KEY>` (bypasses public quotas when configured).
  - Body:
    ```json
    {
      "mode": "initial",
      "messages": [
        { "role": "user", "content": "..." },
        { "role": "assistant", "content": "..." }
      ],
      "reasoning": "..."
    }
    ```
  - Response (`200`):
    ```json
    {
      "title": "Fix reconnect flow",
      "quota": {
        "limit": 50,
        "remaining": 49,
        "resetAt": "2026-11-22T00:00:00.000Z"
      }
    }
    ```

## Quotas & Privacy

- **L1 burst protection**: 10 req/min per device, 20 req/min per IP (Cloudflare Rate Limiting binding).
- **L2 daily limits** (UTC midnight reset, stored in D1): 50/day per device, 300/day per IP, 2,500/day public pool cap.
- Conversation text and generated titles are never logged or stored. D1 stores only salted SHA-256 hashes of device IDs and IP prefixes with daily counters.

## Development & Deployment

```bash
bun install
bun test
bun run typecheck
bun run db:migrate:remote
bun run deploy
```

Recommended production secrets (never commit):

```bash
bunx wrangler secret put QUOTA_SALT
bunx wrangler secret put OWNER_KEY
```
