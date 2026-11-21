export interface QuotaLimits {
  deviceDaily: number;
  ipDaily: number;
  publicPoolDaily: number;
}

export interface QuotaSnapshot {
  limit: number;
  remaining: number;
  resetAt: string;
}

export type QuotaDecision =
  | {
      allowed: true;
      quota: QuotaSnapshot;
    }
  | {
      allowed: false;
      scope: "burst_device" | "burst_ip" | "device" | "ip" | "pool";
      retryAfterSeconds: number;
      quota: QuotaSnapshot;
    };

export interface RateLimitBinding {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface D1StatementLike {
  bind(...values: unknown[]): D1StatementLike;
  all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
}

export interface D1DatabaseLike {
  prepare(query: string): D1StatementLike;
  batch<T = Record<string, unknown>>(statements: D1StatementLike[]): Promise<Array<{ results: T[] }>>;
}

export const DEFAULT_QUOTA_LIMITS: QuotaLimits = {
  deviceDaily: 50,
  ipDaily: 300,
  publicPoolDaily: 2_500,
};

const DEVICE_ID_PATTERN = /^[A-Za-z0-9._:-]{8,128}$/;

export function validateDeviceId(raw: string | null): string | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (!DEVICE_ID_PATTERN.test(trimmed)) return null;
  return trimmed;
}

export function normalizeClientIp(request: Request): string {
  const cfIp = request.headers.get("CF-Connecting-IP")?.trim();
  const forwarded = request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim();
  const ip = cfIp || forwarded || "unknown";
  if (ip.includes(":")) {
    // Group IPv6 clients by /64 subnet to match standard residential allocation.
    const parts = ip.toLowerCase().split(":").slice(0, 4);
    return parts.join(":") + "::/64";
  }
  return ip;
}

export function utcDayKey(now = new Date()): string {
  return now.toISOString().slice(0, 10);
}

export function nextUtcMidnight(now = new Date()): { resetAt: string; retryAfterSeconds: number } {
  const next = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0, 0),
  );
  const retryAfterSeconds = Math.max(1, Math.ceil((next.getTime() - now.getTime()) / 1000));
  return { resetAt: next.toISOString(), retryAfterSeconds };
}

export async function hashQuotaKey(prefix: string, value: string, salt: string): Promise<string> {
  const data = new TextEncoder().encode(`${salt}:${prefix}:${value}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  const hex = Array.from(new Uint8Array(digest))
    .slice(0, 16)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `${prefix}:${hex}`;
}

export function timingSafeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const aBytes = encoder.encode(a);
  const bBytes = encoder.encode(b);
  const maxLen = Math.max(aBytes.length, bBytes.length);
  let diff = aBytes.length ^ bBytes.length;
  for (let i = 0; i < maxLen; i += 1) {
    diff |= (aBytes[i] ?? 0) ^ (bBytes[i] ?? 0);
  }
  return diff === 0;
}

export async function consumeQuota(options: {
  db: D1DatabaseLike;
  deviceId: string;
  clientIp: string;
  salt: string;
  limits: QuotaLimits;
  deviceBurst?: RateLimitBinding;
  ipBurst?: RateLimitBinding;
  now?: Date;
}): Promise<QuotaDecision> {
  const now = options.now ?? new Date();
  const day = utcDayKey(now);
  const { resetAt, retryAfterSeconds } = nextUtcMidnight(now);
  const { deviceDaily, ipDaily, publicPoolDaily } = options.limits;

  const [devKey, ipKey] = await Promise.all([
    hashQuotaKey("dev", options.deviceId, options.salt),
    hashQuotaKey("ip", options.clientIp, options.salt),
  ]);
  const poolKey = "pool:public";

  if (options.deviceBurst) {
    const burst = await options.deviceBurst.limit({ key: devKey });
    if (!burst.success) {
      return {
        allowed: false,
        scope: "burst_device",
        retryAfterSeconds: 60,
        quota: { limit: deviceDaily, remaining: 0, resetAt },
      };
    }
  }

  if (options.ipBurst) {
    const burst = await options.ipBurst.limit({ key: ipKey });
    if (!burst.success) {
      return {
        allowed: false,
        scope: "burst_ip",
        retryAfterSeconds: 60,
        quota: { limit: deviceDaily, remaining: 0, resetAt },
      };
    }
  }

  // Pre-check avoids writing to D1 when a key is already exhausted.
  const existing = await options.db
    .prepare("SELECT key, count FROM daily_quota WHERE day = ? AND key IN (?, ?, ?)")
    .bind(day, devKey, ipKey, poolKey)
    .all<{ key: string; count: number }>();

  const counts = new Map<string, number>();
  for (const row of existing.results) {
    counts.set(row.key, Number(row.count) || 0);
  }

  const devCount = counts.get(devKey) ?? 0;
  const ipCount = counts.get(ipKey) ?? 0;
  const poolCount = counts.get(poolKey) ?? 0;

  if (devCount >= deviceDaily) {
    return {
      allowed: false,
      scope: "device",
      retryAfterSeconds,
      quota: { limit: deviceDaily, remaining: 0, resetAt },
    };
  }
  if (ipCount >= ipDaily) {
    return {
      allowed: false,
      scope: "ip",
      retryAfterSeconds,
      quota: { limit: deviceDaily, remaining: Math.max(0, deviceDaily - devCount), resetAt },
    };
  }
  if (poolCount >= publicPoolDaily) {
    return {
      allowed: false,
      scope: "pool",
      retryAfterSeconds,
      quota: { limit: deviceDaily, remaining: Math.max(0, deviceDaily - devCount), resetAt },
    };
  }

  // Atomic conditional upserts guard against concurrent requests racing past a limit.
  const upsertSQL =
    "INSERT INTO daily_quota (day, key, count) VALUES (?, ?, 1) " +
    "ON CONFLICT(day, key) DO UPDATE SET count = count + 1 WHERE count < ? " +
    "RETURNING count";

  const [devRes, ipRes, poolRes] = await options.db.batch<{ count: number }>([
    options.db.prepare(upsertSQL).bind(day, devKey, deviceDaily),
    options.db.prepare(upsertSQL).bind(day, ipKey, ipDaily),
    options.db.prepare(upsertSQL).bind(day, poolKey, publicPoolDaily),
  ]);

  if (!devRes?.results?.length) {
    return {
      allowed: false,
      scope: "device",
      retryAfterSeconds,
      quota: { limit: deviceDaily, remaining: 0, resetAt },
    };
  }
  if (!ipRes?.results?.length) {
    return {
      allowed: false,
      scope: "ip",
      retryAfterSeconds,
      quota: { limit: deviceDaily, remaining: Math.max(0, deviceDaily - devCount), resetAt },
    };
  }
  if (!poolRes?.results?.length) {
    return {
      allowed: false,
      scope: "pool",
      retryAfterSeconds,
      quota: { limit: deviceDaily, remaining: Math.max(0, deviceDaily - devCount), resetAt },
    };
  }

  const newDevCount = Number(devRes.results[0]?.count ?? devCount + 1);
  return {
    allowed: true,
    quota: {
      limit: deviceDaily,
      remaining: Math.max(0, deviceDaily - newDevCount),
      resetAt,
    },
  };
}
