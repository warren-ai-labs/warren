import test from "node:test";
import assert from "node:assert/strict";

import {
  DOWNLOAD_ANALYTICS_SCHEMA,
  downloadAnalyticsPoint,
  visitorCookieHeader,
  visitorForRequest,
  writeDownloadMetric,
} from "../src/download-analytics.js";

function requestWithCloudflareMetadata(url, init, cf) {
  const request = new Request(url, init);
  Object.defineProperty(request, "cf", { value: cf });
  return request;
}

test("download analytics records coarse context without the raw referrer path", () => {
  const request = requestWithCloudflareMetadata(
    "https://warrenai.xyz/api/download",
    {
      headers: {
        "Accept-Language": "zh-CN,zh;q=0.9",
        Referer: "https://example.com/campaign?email=private@example.com",
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36",
      },
    },
    { country: "CN", colo: "HKG" },
  );

  const point = downloadAnalyticsPoint({
    request,
    release: { tag_name: "v0.5.1", name: "Warren-0.5.1.zip" },
    visitorId: "123e4567-e89b-12d3-a456-426614174000",
  });

  assert.deepEqual(point.blobs, [
    "download_started",
    "v0.5.1",
    "Warren-0.5.1.zip",
    "123e4567-e89b-12d3-a456-426614174000",
    "CN",
    "HKG",
    "Chrome",
    "macOS",
    "desktop",
    "https://example.com",
    "zh-cn",
  ]);
  assert.deepEqual(point.doubles, [1]);
  assert.deepEqual(point.indexes, ["123e4567-e89b-12d3-a456-426614174000"]);
  assert.equal(point.blobs.length, DOWNLOAD_ANALYTICS_SCHEMA.length);
  assert.equal(point.blobs.some((value) => value.includes("private@example.com")), false);
});

test("visitor identity reuses a valid cookie and sets a protected cookie for new visitors", () => {
  const visitorId = "123e4567-e89b-12d3-a456-426614174000";
  const existingRequest = new Request("https://warrenai.xyz/api/download", {
    headers: { Cookie: `warren_visitor=${encodeURIComponent(visitorId)}` },
  });
  assert.deepEqual(visitorForRequest(existingRequest), { id: visitorId, isNew: false });

  const newRequest = new Request("https://warrenai.xyz/api/download");
  const identity = visitorForRequest(newRequest);
  assert.equal(identity.isNew, true);
  assert.match(identity.id, /^[A-Za-z0-9_-]{16,80}$/);
  assert.match(visitorCookieHeader(identity.id), /HttpOnly/);
  assert.match(visitorCookieHeader(identity.id), /Secure/);
  assert.match(visitorCookieHeader(identity.id), /SameSite=Lax/);
});

test("download metrics are optional when the Analytics Engine binding is absent", () => {
  assert.equal(writeDownloadMetric({}, { blobs: [], doubles: [1], indexes: ["visitor"] }), null);

  let received;
  const pending = writeDownloadMetric(
    {
      DOWNLOAD_ANALYTICS: {
        writeDataPoint(point) {
          received = point;
          return Promise.resolve();
        },
      },
    },
    { blobs: ["download_started"], doubles: [1], indexes: ["visitor"] },
  );
  assert.ok(pending instanceof Promise);
  assert.deepEqual(received, {
    blobs: ["download_started"],
    doubles: [1],
    indexes: ["visitor"],
  });
});
