import test from "node:test";
import assert from "node:assert/strict";

import { normalizeRelease, releaseAssetFromHtml } from "../src/worker.js";

test("releaseAssetFromHtml selects a Warren archive and ignores checksums", () => {
  const asset = releaseAssetFromHtml(`
    <a href="/abcdlsj/warren/releases/download/v0.5.1/checksums.txt">checksums</a>
    <a href="/abcdlsj/warren/releases/download/v0.5.1/Warren-0.5.1.zip">Warren</a>
  `);

  assert.deepEqual(asset, {
    name: "Warren-0.5.1.zip",
    path: "/abcdlsj/warren/releases/download/v0.5.1/Warren-0.5.1.zip",
  });
});

test("releaseAssetFromHtml selects a Warren archive with warren-ai-labs path and ignores checksums", () => {
  const asset = releaseAssetFromHtml(`
    <a href="/warren-ai-labs/warren/releases/download/v0.5.1/checksums.txt">checksums</a>
    <a href="/warren-ai-labs/warren/releases/download/v0.5.1/Warren-0.5.1.zip">Warren</a>
  `);

  assert.deepEqual(asset, {
    name: "Warren-0.5.1.zip",
    path: "/warren-ai-labs/warren/releases/download/v0.5.1/Warren-0.5.1.zip",
  });
});

test("normalizeRelease preserves onboarding and desktop response fields", () => {
  const release = normalizeRelease(
    {
      tag_name: "v0.5.1",
      html_url: "https://github.com/abcdlsj/warren/releases/tag/v0.5.1",
      body: "Release notes",
      assets: [
        {
          name: "checksums.txt",
          browser_download_url: "https://example.com/checksums.txt",
          size: 12,
        },
        {
          name: "Warren-0.5.1.zip",
          browser_download_url: "https://example.com/Warren-0.5.1.zip",
          size: 42,
        },
      ],
    },
  );

  assert.equal(release.tag, "v0.5.1");
  assert.equal(release.tag_name, "v0.5.1");
  assert.equal(release.name, "Warren-0.5.1.zip");
  assert.equal(release.size, 42);
  assert.equal(release.url, "https://example.com/Warren-0.5.1.zip");
  assert.deepEqual(release.assets, [
    {
      name: "Warren-0.5.1.zip",
      browser_download_url: "https://example.com/Warren-0.5.1.zip",
      size: 42,
    },
  ]);
});
