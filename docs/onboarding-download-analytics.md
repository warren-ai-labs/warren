# Onboarding Download Analytics

The onboarding Download button calls `GET /api/download`. The Worker resolves
the current release from the existing five-minute release snapshot, writes one
`download_started` point to Workers Analytics Engine, and returns the release
JSON. The browser then follows the release asset URL on GitHub. This measures a
download start/intent; GitHub remains responsible for the actual archive
transfer and completion status.

## Dataset and privacy

The binding is declared in `Onboarding/wrangler.toml`:

```toml
[[analytics_engine_datasets]]
binding = "DOWNLOAD_ANALYTICS"
dataset = "warren_onboarding_downloads"
```

Cloudflare creates the dataset automatically on its first write after deploy.
The Worker does not write the source IP address. It issues a first-party,
`HttpOnly`, `Secure`, one-year `warren_visitor` cookie containing a random
identifier so repeated downloads from the same browser can be counted without
claiming to know a person's identity. The dataset stores these ordered blobs:

| Blob | Dimension | Meaning |
| --- | --- | --- |
| `blob1` | `event` | Always `download_started` |
| `blob2` | `release` | Release tag, for example `v0.5.1` |
| `blob3` | `asset` | Archive name |
| `blob4` | `visitor_id` | Random first-party browser identifier |
| `blob5` | `country` | Cloudflare country code, when available |
| `blob6` | `colo` | Cloudflare edge colo, when available |
| `blob7` | `browser` | Coarse user-agent family |
| `blob8` | `os` | Coarse operating-system family |
| `blob9` | `device` | `desktop`, `tablet`, or `mobile` |
| `blob10` | `referrer_origin` | Referrer origin only, or `direct` |
| `blob11` | `language` | First `Accept-Language` value |

`double1` is `1` for each event. The visitor identifier is also used as the
Analytics Engine sampling index. Analytics Engine queries must account for
`_sample_interval` when summing sampled data points; distinct-visitor results
can be estimates when the dataset is sampled.

## Queries

Create an API token with the account-level Analytics Read permission, then run
queries against the Cloudflare SQL API. Keep the token outside the repository.

Total download starts in the last 30 days:

```sql
SELECT SUM(_sample_interval * double1) AS downloads
FROM warren_onboarding_downloads
WHERE blob1 = 'download_started'
  AND timestamp >= NOW() - INTERVAL '30' DAY
```

Distinct anonymous browsers in the last 30 days:

```sql
SELECT COUNT(DISTINCT blob4) AS visitors
FROM warren_onboarding_downloads
WHERE blob1 = 'download_started'
  AND timestamp >= NOW() - INTERVAL '30' DAY
```

Daily downloads by release:

```sql
SELECT
  intDiv(toUInt32(timestamp), 86400) * 86400 AS day,
  blob2 AS release,
  SUM(_sample_interval * double1) AS downloads
FROM warren_onboarding_downloads
WHERE blob1 = 'download_started'
GROUP BY day, release
ORDER BY day DESC, downloads DESC
```

Breakdown by country, browser, or device (replace `blob5` as needed):

```sql
SELECT
  blob5 AS country,
  SUM(_sample_interval * double1) AS downloads
FROM warren_onboarding_downloads
WHERE blob1 = 'download_started'
GROUP BY country
ORDER BY downloads DESC
```

Recent downloader identifiers and their coarse context:

```sql
SELECT
  timestamp,
  blob4 AS visitor_id,
  blob2 AS release,
  blob5 AS country,
  blob7 AS browser,
  blob8 AS os,
  blob9 AS device,
  blob10 AS referrer_origin
FROM warren_onboarding_downloads
WHERE blob1 = 'download_started'
ORDER BY timestamp DESC
LIMIT 100
```

For example, submit a query with:

```sh
curl "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/analytics_engine/sql" \
  --header "Authorization: Bearer $CF_ANALYTICS_READ_TOKEN" \
  --data-binary @query.sql
```

`/api/update/latest` and `/api/latest-release` do not write download events;
desktop update checks and release metadata reads therefore stay out of the
web-download count.
