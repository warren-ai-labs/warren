import { FALLBACK_MODEL, generateTitle, PRIMARY_MODEL, type AIBinding } from "./ai";
import { buildTitleMessages, parseTitleInput } from "./prompt";
import {
  consumeQuota,
  DEFAULT_QUOTA_LIMITS,
  normalizeClientIp,
  timingSafeEqual,
  validateDeviceId,
  type D1DatabaseLike,
  type QuotaLimits,
  type RateLimitBinding,
} from "./quota";

export interface Env {
  AI: AIBinding;
  DB: D1DatabaseLike;
  DEVICE_BURST?: RateLimitBinding;
  IP_BURST?: RateLimitBinding;
  QUOTA_SALT?: string;
  OWNER_KEY?: string;
  PRIMARY_MODEL?: string;
  FALLBACK_MODEL?: string;
  DEVICE_DAILY_LIMIT?: string;
  IP_DAILY_LIMIT?: string;
  PUBLIC_POOL_DAILY_LIMIT?: string;
}

const MAX_BODY_BYTES = 64 * 1024;
const DEFAULT_SALT = "warren-title-service-v1";

function parsePositiveInt(value: string | undefined, fallback: number): number {
  if (!value) return fallback;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function resolveLimits(env: Env): QuotaLimits {
  return {
    deviceDaily: parsePositiveInt(env.DEVICE_DAILY_LIMIT, DEFAULT_QUOTA_LIMITS.deviceDaily),
    ipDaily: parsePositiveInt(env.IP_DAILY_LIMIT, DEFAULT_QUOTA_LIMITS.ipDaily),
    publicPoolDaily: parsePositiveInt(
      env.PUBLIC_POOL_DAILY_LIMIT,
      DEFAULT_QUOTA_LIMITS.publicPoolDaily,
    ),
  };
}

function isOwnerAuthorized(request: Request, env: Env): boolean {
  const ownerKey = env.OWNER_KEY?.trim();
  if (!ownerKey) return false;
  const header = request.headers.get("Authorization")?.trim() ?? "";
  if (!header.toLowerCase().startsWith("bearer ")) return false;
  const token = header.slice(7).trim();
  if (!token) return false;
  return timingSafeEqual(token, ownerKey);
}

function jsonResponse(
  body: unknown,
  status = 200,
  extraHeaders?: Record<string, string>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}

async function readJsonBody(request: Request): Promise<{ ok: true; data: unknown } | { ok: false; status: number; error: string }> {
  const lengthHeader = request.headers.get("Content-Length");
  if (lengthHeader) {
    const declared = Number.parseInt(lengthHeader, 10);
    if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
      return { ok: false, status: 413, error: "request body too large" };
    }
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) {
    return { ok: false, status: 413, error: "request body too large" };
  }
  try {
    return { ok: true, data: JSON.parse(text) };
  } catch {
    return { ok: false, status: 400, error: "invalid JSON body" };
  }
}

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";

  if (request.method === "GET" && path === "/health") {
    const limits = resolveLimits(env);
    return jsonResponse({
      ok: true,
      service: "warren-title",
      model: env.PRIMARY_MODEL?.trim() || PRIMARY_MODEL,
      limits: {
        deviceDaily: limits.deviceDaily,
        ipDaily: limits.ipDaily,
      },
    });
  }

  if (path !== "/v1/title") {
    return jsonResponse({ error: "not found" }, 404);
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "method not allowed" }, 405, { Allow: "POST" });
  }

  const owner = isOwnerAuthorized(request, env);
  const deviceId = validateDeviceId(request.headers.get("X-Device-Id"));
  if (!owner && !deviceId) {
    return jsonResponse(
      { error: "missing or invalid X-Device-Id header (expected 8-128 safe characters)" },
      400,
    );
  }

  const parsedBody = await readJsonBody(request);
  if (!parsedBody.ok) {
    return jsonResponse({ error: parsedBody.error }, parsedBody.status);
  }

  const titleInput = parseTitleInput(parsedBody.data);
  if ("error" in titleInput) {
    return jsonResponse({ error: titleInput.error }, 400);
  }

  let quotaResponse: { limit: number; remaining: number; resetAt: string } | undefined;
  if (!owner && deviceId) {
    const decision = await consumeQuota({
      db: env.DB,
      deviceId,
      clientIp: normalizeClientIp(request),
      salt: env.QUOTA_SALT?.trim() || DEFAULT_SALT,
      limits: resolveLimits(env),
      deviceBurst: env.DEVICE_BURST,
      ipBurst: env.IP_BURST,
    });
    if (!decision.allowed) {
      const messages: Record<typeof decision.scope, string> = {
        burst_device: "too many requests from this device; please slow down",
        burst_ip: "too many requests from this network; please slow down",
        device: "daily device title quota reached",
        ip: "daily network title quota reached",
        pool: "daily free title service capacity reached",
      };
      return jsonResponse(
        {
          error: messages[decision.scope],
          scope: decision.scope,
          quota: decision.quota,
        },
        429,
        { "Retry-After": String(decision.retryAfterSeconds) },
      );
    }
    quotaResponse = decision.quota;
  }

  try {
    const promptMessages = buildTitleMessages(titleInput);
    const primary = env.PRIMARY_MODEL?.trim() || PRIMARY_MODEL;
    const fallback = env.FALLBACK_MODEL?.trim() || FALLBACK_MODEL;
    const result = await generateTitle(env.AI, promptMessages, primary, fallback);
    return jsonResponse({
      title: result.title,
      ...(quotaResponse ? { quota: quotaResponse } : {}),
    });
  } catch {
    return jsonResponse({ error: "title generation temporarily unavailable" }, 502);
  }
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env);
  },
};
