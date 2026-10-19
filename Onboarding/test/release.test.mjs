import test from "node:test";
import assert from "node:assert/strict";

import { normalizeRelease, releaseAssetsFromHtml } from "../src/worker.js";

test("releaseAssetsFromHtml selects Warren archives and ignores checksums", () => {
  const assets = releaseAssetsFromHtml(`
    <a href="/abcdlsj/warren/releases/download/v0.5.1/checksums.txt">checksums</a>
    <a href="/abcdlsj/warren/releases/download/v0.5.1/Warren-0.5.1.zip">Warren</a>
  `);

  assert.deepEqual(assets, [
    {
      name: "Warren-0.5.1.zip",
      path: "/abcdlsj/warren/releases/download/v0.5.1/Warren-0.5.1.zip",
    },
  ]);
});

test("releaseAssetsFromHtml selects Warren archives with warren-ai-labs path and ignores checksums", () => {
  const assets = releaseAssetsFromHtml(`
    <a href="/warren-ai-labs/warren/releases/download/v0.5.1/checksums.txt">checksums</a>
    <a href="/warren-ai-labs/warren/releases/download/v0.5.1/Warren-0.5.1.zip">Warren</a>
  `);

  assert.deepEqual(assets, [
    {
      name: "Warren-0.5.1.zip",
      path: "/warren-ai-labs/warren/releases/download/v0.5.1/Warren-0.5.1.zip",
    },
  ]);
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

test("releaseAssetsFromHtml keeps every app archive once", () => {
  const assets = releaseAssetsFromHtml(`
    <a href="/warren-ai-labs/warren/releases/download/v0.32.0/Warren-0.32.0.zip">zip</a>
    <a href="/warren-ai-labs/warren/releases/download/v0.32.0/Warren-0.32.0.zip.sha256">sum</a>
    <a href="/warren-ai-labs/warren/releases/download/v0.32.0/Warren-0.32.0.dmg">dmg</a>
    <a href="/warren-ai-labs/warren/releases/download/v0.32.0/Warren-0.32.0.dmg">dmg again</a>
  `);

  assert.deepEqual(
    assets.map((asset) => asset.name),
    ["Warren-0.32.0.zip", "Warren-0.32.0.dmg"],
  );
});

test("normalizeRelease downloads the disk image and keeps the zip for the desktop updater", () => {
  const release = normalizeRelease({
    tag_name: "v0.32.0",
    assets: [
      { name: "Warren-0.32.0.zip", browser_download_url: "https://example.com/Warren-0.32.0.zip", size: 40 },
      { name: "Warren-0.32.0.zip.sha256", browser_download_url: "https://example.com/zip.sha256", size: 1 },
      { name: "Warren-0.32.0.dmg", browser_download_url: "https://example.com/Warren-0.32.0.dmg", size: 50 },
    ],
  });

  assert.equal(release.name, "Warren-0.32.0.dmg");
  assert.equal(release.url, "https://example.com/Warren-0.32.0.dmg");
  assert.equal(release.size, 50);
  assert.deepEqual(
    release.assets.map((asset) => asset.name),
    ["Warren-0.32.0.zip", "Warren-0.32.0.dmg"],
  );
});
