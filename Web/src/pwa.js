import { activityMarkTier, resolveActivityMark } from "./activity.js";

// Safari has no beforeinstallprompt, so the Web client has to recognize the
// one browser where "Add to Home Screen" is the only way to install and say so
// itself. Home Screen web apps on iOS also keep their own storage, separate
// from Safari tabs: a Host paired in a tab is not known to the installed app.

export const installHintStorageKey = "warren.pwa.install-hint-dismissed-at";
export const installHintQuietMs = 14 * 24 * 60 * 60 * 1000;

/// Whether the page runs as an installed app rather than in a browser tab.
export function isStandaloneDisplay(win = globalThis) {
  try {
    if (win?.navigator?.standalone === true) return true;
    return Boolean(win?.matchMedia?.("(display-mode: standalone)")?.matches);
  } catch {
    return false;
  }
}

/// Whether this is Safari (or any WebKit shell) on an iPhone or iPad, where
/// installing means Share › Add to Home Screen.
///
/// iPadOS reports a Mac user agent, so a touch-capable "Macintosh" counts too.
export function isAppleMobileWebKit(nav = globalThis.navigator) {
  const agent = String(nav?.userAgent || "");
  if (/iPhone|iPad|iPod/.test(agent)) return true;
  return /Macintosh/.test(agent) && Number(nav?.maxTouchPoints) > 1;
}

/// The install hint is offered once in a while, only where it can be acted on.
export function shouldOfferInstallHint({ standalone, appleMobile, dismissedAt, now = Date.now() }) {
  if (standalone || !appleMobile) return false;
  const dismissed = Number(dismissedAt);
  return !(Number.isFinite(dismissed) && dismissed > 0 && now - dismissed < installHintQuietMs);
}

export function readInstallHintDismissedAt(storage = globalThis.localStorage) {
  try {
    return Number(storage?.getItem?.(installHintStorageKey)) || 0;
  } catch {
    return 0;
  }
}

export function writeInstallHintDismissedAt(storage = globalThis.localStorage, now = Date.now()) {
  try {
    storage?.setItem?.(installHintStorageKey, String(now));
  } catch {
    // Private browsing may refuse storage; the hint then returns next launch.
  }
}

/// How many Sessions are waiting on a person: approvals, questions, and turns
/// that failed. This is the number the Home Screen icon carries.
///
/// Acknowledgments are ignored on purpose: an actionable mark is never retired
/// by looking at it, only by answering it.
export function actionableSessionCount(sessions) {
  let count = 0;
  for (const session of sessions || []) {
    if (session?.lifecycle && session.lifecycle !== "running") continue;
    if (activityMarkTier(resolveActivityMark(session?.agentStatus)) === "actionable") count += 1;
  }
  return count;
}

/// Mirrors the count onto the app icon where the Badging API exists (installed
/// web apps on iOS 16.4+, Chromium desktop installs). Elsewhere it is a no-op.
export function syncAppBadge(count, nav = globalThis.navigator) {
  try {
    if (count > 0) {
      if (typeof nav?.setAppBadge === "function") return nav.setAppBadge(count).catch(() => {});
    } else if (typeof nav?.clearAppBadge === "function") {
      return nav.clearAppBadge().catch(() => {});
    }
  } catch {
    // A browser that exposes the API but refuses it outside an install throws
    // synchronously in some versions.
  }
  return Promise.resolve();
}

/// Installed apps ask once for storage that survives pressure eviction, so the
/// paired Host and queued messages are not lost. Safari tabs are already subject
/// to a seven-day cap that this cannot lift, which is why only installs ask.
export function requestPersistentStorage(nav = globalThis.navigator) {
  try {
    const storage = nav?.storage;
    if (typeof storage?.persist !== "function") return Promise.resolve(false);
    if (typeof storage.persisted === "function") {
      return storage.persisted()
        .then(already => already || storage.persist())
        .catch(() => false);
    }
    return storage.persist().catch(() => false);
  } catch {
    return Promise.resolve(false);
  }
}
