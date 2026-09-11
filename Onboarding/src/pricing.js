// models.dev catalog projection.
//
// The upstream api.json is a full model catalog: capabilities, modalities,
// limits, and tool support for every provider. Warren only needs four unit
// prices per model, so the catalog is reduced at the edge rather than shipped
// to every Host. That keeps the payload small enough to cache cheaply and,
// more usefully, gives Warren one stable shape to depend on instead of the
// whole upstream schema.

/** Unit prices are quoted per million tokens, in USD. */
export const PRICE_UNIT = "usd-per-million-tokens";

/** Schema version of the projected document, not of the upstream catalog. */
export const PRICING_SCHEMA = 1;

// A model that cannot produce text is not something an Agent CLI bills against,
// and keeping it would make id collisions with real chat models possible.
const NON_TEXT_OUTPUT = new Set(["audio", "image", "video"]);
const NON_TEXT_MARKERS = [
  "audio",
  "embedding",
  "image",
  "moderation",
  "realtime",
  "transcribe",
  "tts",
  "video",
];

/**
 * Reduce a provider model string to its price-lookup identity.
 *
 * Must stay behaviorally identical to NormalizeModelID in
 * Headless/internal/usage/model.go: the Host normalizes the model it observed,
 * this normalizes the catalog key, and a lookup only succeeds if both agree.
 */
export function normalizeModelID(value) {
  let normalized = String(value ?? "").trim();
  if (!normalized) return "";
  const slash = normalized.lastIndexOf("/");
  if (slash >= 0) normalized = normalized.slice(slash + 1);
  const colon = normalized.indexOf(":");
  if (colon >= 0) normalized = normalized.slice(0, colon);
  normalized = normalized.replaceAll("@", "-").toLowerCase().trim();
  if (normalized.endsWith("[1m]")) {
    normalized = normalized.slice(0, -"[1m]".length).trim();
  }
  return normalized;
}

function isTextModel(modelId, model) {
  if (String(model?.status ?? "").toLowerCase() === "deprecated") return false;
  const output = model?.modalities?.output;
  if (Array.isArray(output) && output.length) {
    const lowered = output
      .filter((value) => typeof value === "string")
      .map((value) => value.toLowerCase());
    if (!lowered.includes("text")) return false;
    if (lowered.some((value) => NON_TEXT_OUTPUT.has(value))) return false;
  }
  const haystack = `${modelId} ${model?.name ?? ""}`.toLowerCase();
  return !NON_TEXT_MARKERS.some((marker) => haystack.includes(marker));
}

// Providers that publish their own list prices. The catalog also contains 200+
// gateways and resellers that re-list the same models, and because a reseller
// often carries a discounted or incomplete entry under the same release date,
// picking between them by date alone is arbitrary: observed live, a reseller
// won `claude-haiku-4-5-20251001` with input 0.9 and no cache prices where
// Anthropic lists 1.0 with cache read 0.1 and cache write 1.25.
//
// Ranking first-party keeps the price Warren shows equal to the price the CLI's
// own vendor charges, which is the number a person can reconcile against a bill.
const FIRST_PARTY_PROVIDERS = new Set([
  "alibaba",
  "anthropic",
  "deepseek",
  "google",
  "longcat",
  "minimax",
  "minimax-cn",
  "mistral",
  "moonshotai",
  "openai",
  "xai",
  "xiaomi",
  "zai",
]);

/** A price the catalog did not state. Null, never zero: see priceOf. */
function priceOf(value) {
  // Zero and absent are different facts. A model listed without cache pricing
  // must not be recorded as having free cache, or cached tokens vanish from
  // the bill. The Host renders null as unpriced and says so.
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return null;
  return value;
}

/**
 * Rank a candidate entry for the same normalized model id. Higher wins.
 *
 * Preference order: a first-party provider, then an unprefixed catalog key
 * (resellers namespace the upstream vendor into the key), then an entry that
 * actually states cache prices, then the newest release.
 */
function candidateRank(providerId, rawKey, entry) {
  return [
    FIRST_PARTY_PROVIDERS.has(providerId) ? 1 : 0,
    rawKey.includes("/") ? 0 : 1,
    entry.cacheRead !== null || entry.cacheWrite !== null ? 1 : 0,
    entry.release,
  ];
}

function outranks(next, current) {
  for (let index = 0; index < next.length; index += 1) {
    if (next[index] === current[index]) continue;
    return next[index] > current[index];
  }
  return false;
}

/**
 * Project the upstream catalog into `{ models: { <normalizedId>: entry } }`.
 *
 * One model id is re-listed by dozens of providers, so collisions are the norm
 * rather than the exception and are resolved by candidateRank. Entries stating
 * neither an input nor an output price are dropped: that is missing data, and a
 * Host storing it as a real price would report confident-looking free spend.
 */
export function projectPricing(catalog) {
  if (!catalog || typeof catalog !== "object") {
    throw new Error("models.dev catalog is not an object");
  }
  const models = {};
  const ranks = new Map();
  let considered = 0;
  for (const [providerId, provider] of Object.entries(catalog)) {
    if (!provider || typeof provider !== "object") continue;
    const entries = provider.models;
    if (!entries || typeof entries !== "object") continue;
    for (const [modelId, model] of Object.entries(entries)) {
      considered += 1;
      if (!isTextModel(modelId, model)) continue;
      const cost = model?.cost;
      const input = priceOf(cost?.input);
      const output = priceOf(cost?.output);
      if (input === null && output === null) continue;
      const id = normalizeModelID(modelId);
      if (!id) continue;
      const entry = {
        provider: providerId,
        name: typeof model?.name === "string" && model.name ? model.name : modelId,
        release: typeof model?.release_date === "string" ? model.release_date : "",
        input,
        output,
        cacheRead: priceOf(cost?.cache_read),
        cacheWrite: priceOf(cost?.cache_write),
      };
      const rank = candidateRank(providerId, modelId, entry);
      if (id in models && !outranks(rank, ranks.get(id))) continue;
      models[id] = entry;
      ranks.set(id, rank);
    }
  }
  const count = Object.keys(models).length;
  if (count === 0) {
    throw new Error(`models.dev catalog yielded no priced models from ${considered} entries`);
  }
  return { schema: PRICING_SCHEMA, unit: PRICE_UNIT, count, models };
}
