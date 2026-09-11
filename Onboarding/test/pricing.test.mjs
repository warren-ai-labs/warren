import assert from "node:assert/strict";
import { test } from "node:test";

import { normalizeModelID, projectPricing, PRICE_UNIT } from "../src/pricing.js";

test("normalizeModelID strips routing prefixes, variants, and window markers", () => {
  assert.equal(normalizeModelID("anthropic/claude-opus-5"), "claude-opus-5");
  assert.equal(normalizeModelID("claude-opus-5[1m]"), "claude-opus-5");
  assert.equal(normalizeModelID("gpt-5.5:thinking"), "gpt-5.5");
  assert.equal(normalizeModelID("gemini-2.5-pro@20260101"), "gemini-2.5-pro-20260101");
  // Observed in real Codex rollouts: a routed model keeps its gateway prefix.
  assert.equal(normalizeModelID("z-ai/glm-5.3-flash"), "glm-5.3-flash");
  assert.equal(normalizeModelID("  CLAUDE-Opus-5  "), "claude-opus-5");
  assert.equal(normalizeModelID(""), "");
  assert.equal(normalizeModelID(undefined), "");
});

test("projectPricing keeps the four unit prices per model", () => {
  const document = projectPricing({
    anthropic: {
      models: {
        "claude-opus-5": {
          name: "Claude Opus 5",
          release_date: "2026-05-01",
          cost: { input: 5, output: 25, cache_read: 0.5, cache_write: 6.25 },
        },
      },
    },
  });
  assert.equal(document.unit, PRICE_UNIT);
  assert.equal(document.count, 1);
  assert.deepEqual(document.models["claude-opus-5"], {
    provider: "anthropic",
    name: "Claude Opus 5",
    release: "2026-05-01",
    input: 5,
    output: 25,
    cacheRead: 0.5,
    cacheWrite: 6.25,
  });
});

test("projectPricing prefers the first-party vendor over a reseller", () => {
  // Live regression: resellers re-list the same model, often discounted and
  // without cache prices, under the same release date. Anthropic's own entry
  // must win regardless of iteration order.
  const document = projectPricing({
    "nano-gpt": {
      models: {
        "anthropic/claude-haiku-4-5": {
          release_date: "2025-10-15",
          cost: { input: 0.9, output: 4.5 },
        },
      },
    },
    anthropic: {
      models: {
        "claude-haiku-4-5": {
          release_date: "2025-10-15",
          cost: { input: 1, output: 5, cache_read: 0.1, cache_write: 1.25 },
        },
      },
    },
  });
  const entry = document.models["claude-haiku-4-5"];
  assert.equal(entry.provider, "anthropic");
  assert.equal(entry.input, 1);
  assert.equal(entry.cacheWrite, 1.25);
});

test("projectPricing prefers a stated cache price among equal-tier candidates", () => {
  const document = projectPricing({
    "gateway-a": {
      models: { "some-model": { release_date: "2026-01-01", cost: { input: 1, output: 2 } } },
    },
    "gateway-b": {
      models: {
        "some-model": {
          release_date: "2026-01-01",
          cost: { input: 1, output: 2, cache_read: 0.1, cache_write: 1.25 },
        },
      },
    },
  });
  assert.equal(document.models["some-model"].provider, "gateway-b");
});

test("projectPricing reports an absent cache price as null, not zero", () => {
  // Zero would mean cached tokens are free and silently drop them from the
  // bill; null lets the Host mark the model partially priced instead.
  const document = projectPricing({
    anthropic: {
      models: { "claude-x": { cost: { input: 5, output: 25 } } },
    },
  });
  assert.equal(document.models["claude-x"].cacheRead, null);
  assert.equal(document.models["claude-x"].cacheWrite, null);
});

test("projectPricing drops deprecated models and non-text output modalities", () => {
  const document = projectPricing({
    openai: {
      models: {
        "gpt-5.5": { cost: { input: 1, output: 2 } },
        "gpt-old": { status: "deprecated", cost: { input: 1, output: 2 } },
        // Modality is the reliable signal; a name alone need not say "audio".
        "gpt-realtime-preview": {
          modalities: { output: ["audio"] },
          cost: { input: 1, output: 2 },
        },
        "sora-2": { modalities: { output: ["video"] }, cost: { input: 1, output: 2 } },
      },
    },
  });
  assert.deepEqual(Object.keys(document.models), ["gpt-5.5"]);
});

test("projectPricing drops models named after non-text capabilities", () => {
  // Some catalog entries omit modalities, so the name markers are the only
  // available signal for them.
  const document = projectPricing({
    openai: {
      models: {
        "gpt-5.5": { cost: { input: 1, output: 2 } },
        "gpt-4o-audio-preview": { cost: { input: 1, output: 2 } },
        "text-embedding-4": { cost: { input: 1, output: 2 } },
        "omni-moderation-latest": { cost: { input: 1, output: 2 } },
      },
    },
  });
  assert.deepEqual(Object.keys(document.models), ["gpt-5.5"]);
});

test("projectPricing drops entries stating no input or output price", () => {
  const document = projectPricing({
    openai: {
      models: {
        "gpt-5.5": { cost: { input: 1, output: 2 } },
        "gpt-unpriced": { cost: { cache_read: 0.1 } },
        "gpt-nocost": {},
      },
    },
  });
  assert.deepEqual(Object.keys(document.models), ["gpt-5.5"]);
});

test("projectPricing falls back to newest release among equal-tier candidates", () => {
  const document = projectPricing({
    a: {
      models: {
        "vendor/model-x": { release_date: "2026-01-01", cost: { input: 1, output: 1 } },
      },
    },
    b: {
      models: {
        "other/model-x": { release_date: "2026-06-01", cost: { input: 9, output: 9 } },
      },
    },
  });
  assert.equal(document.count, 1);
  assert.equal(document.models["model-x"].input, 9);
  assert.equal(document.models["model-x"].release, "2026-06-01");
});

test("projectPricing rejects a catalog that yields nothing priceable", () => {
  // An upstream shape change must fail loudly rather than be cached as an
  // empty price table, which would silently make every model unpriced.
  assert.throws(() => projectPricing({ openai: { models: {} } }), /no priced models/);
  assert.throws(() => projectPricing({ openai: { data: [] } }), /no priced models/);
  assert.throws(() => projectPricing(null), /not an object/);
});
