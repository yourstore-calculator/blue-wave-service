// Blue Wave Service — service worker
// Caches the app shell (HTML, manifest, icons) so the app opens instantly and
// works offline once it has been loaded at least once. This is a "same-origin
// only" cache: it deliberately does NOT try to cache cross-origin CDN scripts
// (Font Awesome, Google Fonts, pdf.js, qrcodejs) because those are opaque
// no-cors responses that can't be reliably verified here — the browser's own
// normal HTTP cache usually keeps those available after the first successful
// load anyway, but that's not a guarantee. See the README for how to self-host
// those dependencies if you need airtight 100% offline for every feature.

const CACHE_NAME = "bluewave-shell-v1";
const APP_SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png",
  "./icon-maskable-192.png",
  "./icon-maskable-512.png",
  "./apple-touch-icon.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .catch((err) => console.warn("SW install cache error:", err))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;

  event.respondWith(
    caches.match(event.request).then((cached) => {
      const network = fetch(event.request)
        .then((response) => {
          // Only cache same-origin, successful (non-opaque) responses.
          if (response && response.status === 200 && response.type === "basic") {
            const clone = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
          }
          return response;
        })
        .catch(() => cached);
      return cached || network;
    })
  );
});
