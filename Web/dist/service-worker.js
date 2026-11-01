const CACHE = "warren-vite-v20";
const SHELL = [
  ".", "./manifest.webmanifest", "./icon.svg", "./favicon-16.png", "./favicon-32.png", "./icon-192.png", "./icon-512.png",
  "./apple-touch-icon.png", "./assets/app.js", "./assets/app.css",
  "./assets/react.js", "./assets/xterm.js",
];
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
  self.skipWaiting();
});
self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith("warren-") && key !== CACHE).map(key => caches.delete(key)),
  )));
  self.clients.claim();
});
self.addEventListener("fetch", event => {
  const pathname = new URL(event.request.url).pathname;
  if (event.request.method !== "GET" || pathname.includes("/v1/ws") || pathname.includes("/v1/client/connect")) return;
  // An installed app launched offline, or from a link that carries navigation
  // state (?session=…), still has to open the cached shell so it can say the
  // Host is unreachable instead of showing the browser's own error page.
  const offline = event.request.mode === "navigate"
    ? () => caches.match(event.request, { ignoreSearch: true }).then(hit => hit || caches.match("."))
    : () => caches.match(event.request);
  event.respondWith(fetch(event.request).catch(offline));
});
