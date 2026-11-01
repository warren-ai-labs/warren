import assert from "node:assert/strict";
import test from "node:test";

import {
  actionableSessionCount,
  installHintQuietMs,
  isAppleMobileWebKit,
  isStandaloneDisplay,
  readInstallHintDismissedAt,
  requestPersistentStorage,
  shouldOfferInstallHint,
  syncAppBadge,
  writeInstallHintDismissedAt,
} from "./pwa.js";

const iPhoneSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const macSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
const androidChrome = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36";

test("standalone is read from Safari's flag or the display-mode query", () => {
  assert.equal(isStandaloneDisplay({ navigator: { standalone: true } }), true);
  assert.equal(isStandaloneDisplay({ navigator: {}, matchMedia: () => ({ matches: true }) }), true);
  assert.equal(isStandaloneDisplay({ navigator: {}, matchMedia: () => ({ matches: false }) }), false);
  assert.equal(isStandaloneDisplay({ navigator: {}, matchMedia() { throw new Error("no"); } }), false);
});

test("iPhone and touch iPad count as Apple mobile WebKit, a Mac and Android do not", () => {
  assert.equal(isAppleMobileWebKit({ userAgent: iPhoneSafari }), true);
  assert.equal(isAppleMobileWebKit({ userAgent: macSafari, maxTouchPoints: 5 }), true);
  assert.equal(isAppleMobileWebKit({ userAgent: macSafari, maxTouchPoints: 0 }), false);
  assert.equal(isAppleMobileWebKit({ userAgent: androidChrome, maxTouchPoints: 5 }), false);
});

test("the install hint shows only in an iOS browser tab and stays quiet after a dismissal", () => {
  const now = 1_000_000_000_000;
  assert.equal(shouldOfferInstallHint({ standalone: false, appleMobile: true, dismissedAt: 0, now }), true);
  assert.equal(shouldOfferInstallHint({ standalone: true, appleMobile: true, dismissedAt: 0, now }), false);
  assert.equal(shouldOfferInstallHint({ standalone: false, appleMobile: false, dismissedAt: 0, now }), false);
  assert.equal(shouldOfferInstallHint({ standalone: false, appleMobile: true, dismissedAt: now - 1000, now }), false);
  assert.equal(
    shouldOfferInstallHint({ standalone: false, appleMobile: true, dismissedAt: now - installHintQuietMs - 1, now }),
    true,
  );
});

test("the dismissal survives in storage and tolerates refusing storage", () => {
  const values = new Map();
  const storage = { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
  assert.equal(readInstallHintDismissedAt(storage), 0);
  writeInstallHintDismissedAt(storage, 42);
  assert.equal(readInstallHintDismissedAt(storage), 42);
  const refusing = { getItem() { throw new Error("denied"); }, setItem() { throw new Error("denied"); } };
  assert.equal(readInstallHintDismissedAt(refusing), 0);
  assert.doesNotThrow(() => writeInstallHintDismissedAt(refusing, 1));
});

test("the badge counts Sessions waiting on a person, not working or finished ones", () => {
  const sessions = [
    { agentStatus: { activity: "working" } },
    { agentStatus: { activity: "ready" } },
    { agentStatus: { activity: "blocked", attention: { kind: "approval" } } },
    { agentStatus: { activity: "working", attention: { kind: "input" } } },
    { agentStatus: { activity: "failed" } },
    { agentStatus: { activity: "blocked", attention: { kind: "approval" } }, lifecycle: "ended" },
    { agentStatus: null },
    {},
  ];
  assert.equal(actionableSessionCount(sessions), 3);
  assert.equal(actionableSessionCount(undefined), 0);
});

test("the badge is set, cleared, and skipped where the API is missing", async () => {
  const calls = [];
  const nav = {
    setAppBadge: async count => calls.push(["set", count]),
    clearAppBadge: async () => calls.push(["clear"]),
  };
  await syncAppBadge(2, nav);
  await syncAppBadge(0, nav);
  await syncAppBadge(3, {});
  await syncAppBadge(1, { setAppBadge: () => Promise.reject(new Error("not installed")) });
  assert.deepEqual(calls, [["set", 2], ["clear"]]);
});

test("persistent storage is requested once and never throws", async () => {
  let asked = 0;
  assert.equal(await requestPersistentStorage({ storage: { persisted: async () => true, persist: async () => { asked += 1; return true; } } }), true);
  assert.equal(asked, 0);
  assert.equal(await requestPersistentStorage({ storage: { persisted: async () => false, persist: async () => { asked += 1; return true; } } }), true);
  assert.equal(asked, 1);
  assert.equal(await requestPersistentStorage({}), false);
  assert.equal(await requestPersistentStorage({ storage: { persist: () => Promise.reject(new Error("no")) } }), false);
});
