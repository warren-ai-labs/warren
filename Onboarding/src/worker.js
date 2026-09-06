import { parseChangelog } from "./changelog.js";

const securityHeaders = {
  "Content-Security-Policy":
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' data: ws: wss:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

const RELEASE_API = "https://api.github.com/repos/warren-ai-labs/warren/releases/latest";
const RELEASE_PAGE = "https://github.com/warren-ai-labs/warren/releases/latest";
const RELEASE_CACHE_KEY = new Request("https://warrenai.xyz/__cache/latest-release");
const RELEASE_TTL_MS = 5 * 60 * 1000;
const RELEASE_CACHE_CONTROL = "public, max-age=300, stale-while-revalidate=3600";
const RELEASE_USER_AGENT = "warren-release-proxy";
const CHANGELOG_SOURCE = "https://raw.githubusercontent.com/warren-ai-labs/warren/main/CHANGELOG.md";
const CHANGELOG_CACHE_KEY = new Request("https://warrenai.xyz/__cache/changelog");
const CHANGELOG_TTL_MS = 5 * 60 * 1000;
const CHANGELOG_CACHE_CONTROL = "public, max-age=300, stale-while-revalidate=3600";

export function releaseAssetFromHtml(html) {
  const matches = html.matchAll(
    /href="(\/(?:abcdlsj|warren-ai-labs)\/warren\/releases\/download\/[^"]+?)"/g,
  );
  for (const match of matches) {
    const name = decodeURIComponent(match[1].split("/").pop() ?? "");
    if (/^Warren-.*\.(dmg|pkg|zip)$/i.test(name)) {
      return { name, path: match[1] };
    }
  }
  return null;
}

export function normalizeRelease(release, selectedAsset = null) {
  const tag = release.tag_name ?? release.tag;
  const sourceAsset =
    selectedAsset ??
    release.assets?.find((item) => /^Warren-.*\.(dmg|pkg|zip)$/i.test(item.name)) ??
    release.assets?.[0];
  const downloadURL = sourceAsset?.browser_download_url ?? sourceAsset?.url;

  if (!tag || !sourceAsset?.name || !downloadURL) {
    throw new Error("Latest release has no downloadable asset");
  }

  const htmlURL = release.html_url ?? `https://github.com/warren-ai-labs/warren/releases/tag/${tag}`;
  const asset = {
    name: sourceAsset.name,
    browser_download_url: downloadURL,
    size: Number.isFinite(sourceAsset.size) ? sourceAsset.size : null,
  };

  // Keep the compact fields for the onboarding page while also exposing the
  // GitHub-compatible shape consumed by the desktop updater.
  return {
    tag,
    tag_name: tag,
    html_url: htmlURL,
    body: release.body ?? null,
    assets: [asset],
    name: asset.name,
    size: asset.size,
    url: asset.browser_download_url,
  };
}

async function latestReleaseFromHtml() {
  const latest = await fetch(RELEASE_PAGE, {
    redirect: "follow",
    headers: { "User-Agent": RELEASE_USER_AGENT },
  });
  if (!latest.ok) {
    throw new Error(`GitHub releases page responded with ${latest.status}`);
  }
  const tag = decodeURIComponent(new URL(latest.url).pathname.split("/").pop() ?? "");
  if (!tag) {
    throw new Error("Could not resolve the latest release tag");
  }
  const assets = await fetch(
    `https://github.com/warren-ai-labs/warren/releases/expanded_assets/${tag}`,
    { headers: { "User-Agent": RELEASE_USER_AGENT } },
  );
  if (!assets.ok) {
    throw new Error(`GitHub assets page responded with ${assets.status}`);
  }
  const asset = releaseAssetFromHtml(await assets.text());
  if (!asset) {
    throw new Error("Latest release has no downloadable asset");
  }
  return normalizeRelease(
    {
      tag_name: tag,
      html_url: `https://github.com/warren-ai-labs/warren/releases/tag/${tag}`,
    },
    {
      name: asset.name,
      browser_download_url: `https://github.com${asset.path}`,
      size: null,
    },
  );
}

async function latestReleaseFromAPI(env) {
  const token = env?.GITHUB_TOKEN?.trim();
  if (!token) return null;

  const response = await fetch(RELEASE_API, {
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "User-Agent": RELEASE_USER_AGENT,
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
  if (!response.ok) {
    throw new Error(`GitHub API responded with ${response.status}`);
  }
  return normalizeRelease(await response.json());
}

async function latestRelease(env) {
  // Never spend the Worker's unauthenticated GitHub API quota. A token is
  // optional because the HTML resolver is a rate-limit-safe fallback.
  try {
    const release = await latestReleaseFromAPI(env);
    if (release) return { release, source: "github-api" };
  } catch {
    // Fall through to the release page when a secret is missing or stale.
  }
  return { release: await latestReleaseFromHtml(), source: "github-html" };
}

function releaseResponse(release, cachedAt = Date.now(), source = "unknown") {
  return new Response(JSON.stringify(release), {
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": RELEASE_CACHE_CONTROL,
      "CDN-Cache-Control": RELEASE_CACHE_CONTROL,
      "Cloudflare-CDN-Cache-Control": RELEASE_CACHE_CONTROL,
      "Content-Type": "application/json; charset=utf-8",
      "X-Warren-Release-Cached-At": String(cachedAt),
      "X-Warren-Release-Source": source,
    },
  });
}

function markReleaseStale(response) {
  const headers = new Headers(response.headers);
  headers.set("X-Warren-Release-Stale", "true");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

async function readCachedRelease() {
  const response = await caches.default.match(RELEASE_CACHE_KEY);
  if (!response) return null;
  const cachedAt = Number(response.headers.get("X-Warren-Release-Cached-At"));
  return {
    response,
    fresh: Number.isFinite(cachedAt) && Date.now() - cachedAt < RELEASE_TTL_MS,
  };
}

async function refreshRelease(env) {
  const { release, source } = await latestRelease(env);
  const response = releaseResponse(release, Date.now(), source);
  await caches.default.put(RELEASE_CACHE_KEY, response.clone());
  return response;
}

async function latestReleaseResponseForRequest(ctx, env) {
  const cached = await readCachedRelease();
  if (cached?.fresh) return cached.response;

  if (cached) {
    ctx.waitUntil(refreshRelease(env).catch(() => undefined));
    return markReleaseStale(cached.response);
  }

  try {
    return await refreshRelease(env);
  } catch {
    return Response.json(
      { error: "Could not resolve the latest Warren release." },
      {
        status: 502,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Cache-Control": "no-store",
        },
      },
    );
  }
}

function changelogResponse(entries, cachedAt = Date.now()) {
  return new Response(
    JSON.stringify({ entries, cachedAt: new Date(cachedAt).toISOString() }),
    {
      headers: {
        "Cache-Control": CHANGELOG_CACHE_CONTROL,
        "Content-Type": "application/json; charset=utf-8",
        "X-Warren-Changelog-Cached-At": String(cachedAt),
      },
    },
  );
}

function markStale(response) {
  const headers = new Headers(response.headers);
  headers.set("X-Warren-Changelog-Stale", "true");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

async function readCachedChangelog() {
  const response = await caches.default.match(CHANGELOG_CACHE_KEY);
  if (!response) return null;
  const cachedAt = Number(response.headers.get("X-Warren-Changelog-Cached-At"));
  return {
    response,
    fresh: Number.isFinite(cachedAt) && Date.now() - cachedAt < CHANGELOG_TTL_MS,
  };
}

async function refreshChangelog() {
  const upstream = await fetch(CHANGELOG_SOURCE, {
    headers: { Accept: "text/plain", "User-Agent": "warren-onboarding" },
  });
  if (!upstream.ok) {
    throw new Error(`GitHub changelog responded with ${upstream.status}`);
  }

  const entries = parseChangelog(await upstream.text());
  if (!entries.length) {
    throw new Error("GitHub changelog did not contain any released entries");
  }

  const response = changelogResponse(entries);
  await caches.default.put(CHANGELOG_CACHE_KEY, response.clone());
  return response;
}

async function changelogResponseForRequest(ctx) {
  const cached = await readCachedChangelog();
  if (cached?.fresh) return cached.response;

  if (cached) {
    ctx.waitUntil(refreshChangelog().catch(() => undefined));
    return markStale(cached.response);
  }

  try {
    return await refreshChangelog();
  } catch {
    return Response.json(
      { error: "Could not resolve the repository changelog." },
      { status: 502 },
    );
  }
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return Response.json({ ok: true, service: "warren-onboarding" });
    }

    if (url.pathname === "/api/latest-release" || url.pathname === "/api/update/latest") {
      return latestReleaseResponseForRequest(ctx, env);
    }

    if (url.pathname === "/api/changelog") {
      return changelogResponseForRequest(ctx);
    }

    // The ASSETS binding rewrites unknown paths to "/" with a redirect, so
    // pretty routes like /zh and /en fetch the root document instead.
    const isFileRequest = url.pathname !== "/" && url.pathname.match(/\.[a-zA-Z0-9]+$/);
    const target = isFileRequest
      ? request
      : (() => {
          // Keep the document fresh after an asset deployment; hashed files remain cacheable.
          const assetUrl = new URL("/" + url.search, url);
          assetUrl.searchParams.set("__warren_document_nonce", Date.now().toString(36));
          return new Request(assetUrl, request);
        })();
    const response = await env.ASSETS.fetch(target);

    const headers = new Headers(response.headers);
    for (const [key, value] of Object.entries(securityHeaders)) {
      headers.set(key, value);
    }
    if (!isFileRequest) {
      headers.set("Cache-Control", "no-store");
    }

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};
