// Blue Wave Service — service worker
// =====================================================================================
// إصلاح مهم: النسخة السابقة كانت "الذاكرة أولاً" لكل شيء (return cached || network)،
// فكانت تقدّم صفحة قديمة إلى الأبد ولا يرى المستخدم أي تحديث ترفعه.
//
// الآن: الصفحة (HTML) شبكة أولاً — دائماً أحدث نسخة، والذاكرة احتياطي عند انقطاع النت.
// الملفات الثابتة (الأيقونات) ذاكرة أولاً لأنها لا تتغير وتحميلها من الذاكرة أسرع.
// =====================================================================================

const CACHE_VERSION = "v3";                     // ارفع الرقم مع كل تحديث لتنظيف القديم
const CACHE_NAME = `bluewave-shell-${CACHE_VERSION}`;

const STATIC_ASSETS = [
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
      .then((cache) => cache.addAll(STATIC_ASSETS))
      .catch((err) => console.warn("SW install cache error:", err))
  );
  self.skipWaiting();                            // فعّل النسخة الجديدة فوراً
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

// يسمح للصفحة بطلب التفعيل الفوري
self.addEventListener("message", (event) => {
  if (event.data === "SKIP_WAITING") self.skipWaiting();
});

function isPageRequest(request) {
  return request.mode === "navigate" ||
         (request.destination === "document") ||
         (request.headers.get("accept") || "").includes("text/html");
}

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;

  // ---------- الصفحة: شبكة أولاً ----------
  if (isPageRequest(event.request)) {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          if (response && response.status === 200 && response.type === "basic") {
            const clone = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
          }
          return response;
        })
        .catch(() => caches.match(event.request).then(c => c || caches.match("./index.html")))
    );
    return;
  }

  // ---------- الملفات الثابتة: ذاكرة أولاً ----------
  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).then((response) => {
        if (response && response.status === 200 && response.type === "basic") {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        }
        return response;
      });
    })
  );
});
