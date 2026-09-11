const VISITOR_COOKIE = "warren_visitor";
const VISITOR_COOKIE_MAX_AGE = 60 * 60 * 24 * 365;
const VISITOR_ID_PATTERN = /^[A-Za-z0-9_-]{16,80}$/;
const MAX_DIMENSION_LENGTH = 128;

export const DOWNLOAD_EVENT = "download_started";

export const DOWNLOAD_ANALYTICS_SCHEMA = Object.freeze([
  "event",
  "release",
  "asset",
  "visitor_id",
  "country",
  "colo",
  "browser",
  "os",
  "device",
  "referrer_origin",
  "language",
]);

function dimension(value) {
  const normalized = String(value ?? "").trim();
  return normalized ? normalized.slice(0, MAX_DIMENSION_LENGTH) : "unknown";
}

function readCookie(request, name) {
  const header = request.headers.get("Cookie") ?? "";
  for (const item of header.split(";")) {
    const separator = item.indexOf("=");
    if (separator < 0) continue;
    const key = item.slice(0, separator).trim();
    if (key !== name) continue;
    const value = item.slice(separator + 1).trim();
    try {
      return decodeURIComponent(value);
    } catch {
      return value;
    }
  }
  return null;
}

function createVisitorId() {
  if (typeof globalThis.crypto?.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }

  const bytes = new Uint8Array(16);
  if (typeof globalThis.crypto?.getRandomValues === "function") {
    globalThis.crypto.getRandomValues(bytes);
  } else {
    const fallback = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
    return fallback.padEnd(16, "0").slice(0, 32);
  }
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function visitorForRequest(request) {
  const existing = readCookie(request, VISITOR_COOKIE);
  if (existing && VISITOR_ID_PATTERN.test(existing)) {
    return { id: existing, isNew: false };
  }
  return { id: createVisitorId(), isNew: true };
}

export function visitorCookieHeader(visitorId) {
  return `${VISITOR_COOKIE}=${encodeURIComponent(visitorId)}; Max-Age=${VISITOR_COOKIE_MAX_AGE}; Path=/; Secure; HttpOnly; SameSite=Lax`;
}

function classifyBrowser(userAgent) {
  if (/SamsungBrowser\//i.test(userAgent)) return "Samsung Internet";
  if (/Edg\//i.test(userAgent)) return "Edge";
  if (/OPR\//i.test(userAgent)) return "Opera";
  if (/CriOS\//i.test(userAgent)) return "Chrome iOS";
  if (/Chrome\//i.test(userAgent)) return "Chrome";
  if (/FxiOS\//i.test(userAgent)) return "Firefox iOS";
  if (/Firefox\//i.test(userAgent)) return "Firefox";
  if (/Version\/.*Safari\//i.test(userAgent)) return "Safari";
  if (/AppleWebKit\//i.test(userAgent)) return "WebKit";
  return "Other";
}

function classifyOS(userAgent) {
  if (/(?:iPhone|iPad|iPod)/i.test(userAgent)) return "iOS";
  if (/Android/i.test(userAgent)) return "Android";
  if (/Windows/i.test(userAgent)) return "Windows";
  if (/(?:Macintosh|Mac OS X)/i.test(userAgent)) return "macOS";
  if (/CrOS/i.test(userAgent)) return "ChromeOS";
  if (/Linux/i.test(userAgent)) return "Linux";
  return "Other";
}

function classifyDevice(userAgent) {
  if (/(?:iPad|Tablet)/i.test(userAgent)) return "tablet";
  if (/(?:Mobile|iPhone|iPod|Android)/i.test(userAgent)) return "mobile";
  return "desktop";
}

function languageFromRequest(request) {
  return dimension((request.headers.get("Accept-Language") ?? "").split(",", 1)[0]).toLowerCase();
}

function referrerOrigin(request) {
  const value = request.headers.get("Referer");
  if (!value) return "direct";
  try {
    const origin = new URL(value).origin;
    return origin === new URL(request.url).origin ? "same-origin" : dimension(origin);
  } catch {
    return "unknown";
  }
}

function requestLocation(request) {
  const cf = request.cf ?? {};
  return {
    country: dimension(cf.country).toUpperCase(),
    colo: dimension(cf.colo),
  };
}

export function downloadAnalyticsPoint({ request, release, visitorId }) {
  const userAgent = request.headers.get("User-Agent") ?? "";
  const location = requestLocation(request);
  const blobs = [
    DOWNLOAD_EVENT,
    dimension(release?.tag_name ?? release?.tag),
    dimension(release?.name),
    dimension(visitorId),
    location.country,
    location.colo,
    classifyBrowser(userAgent),
    classifyOS(userAgent),
    classifyDevice(userAgent),
    referrerOrigin(request),
    languageFromRequest(request),
  ];

  return {
    blobs,
    doubles: [1],
    indexes: [dimension(visitorId)],
  };
}

export function writeDownloadMetric(env, point) {
  const analytics = env?.DOWNLOAD_ANALYTICS;
  if (!analytics || typeof analytics.writeDataPoint !== "function") return null;

  try {
    const result = analytics.writeDataPoint(point);
    return result && typeof result.then === "function" ? result.catch(() => undefined) : null;
  } catch {
    return null;
  }
}
