/* PWA — مطبعة ذكرى.
   تخزين أيقونات التطبيق فقط. لا نخزّن بيانات الزبائن أو الطلبات أو ردود Supabase. */
const CACHE_VERSION = 'zikra-pwa-v1';
const APP_ICONS = ['./pwa-icon-192.png?v=2', './pwa-icon-512.png?v=2', './pwa-icon-maskable.png?v=2', './apple-touch-icon.png?v=2'];
const OFFLINE_PAGE = `<!doctype html>
<html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#1c3168"><title>ذكرى — غير متصل</title>
<style>*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f8fb;color:#1c3168;font-family:Tahoma,Arial,sans-serif;padding:24px;text-align:center}.box{max-width:420px;padding:36px 24px;border-radius:22px;background:#fff;box-shadow:0 12px 40px #1c31681c}h1{font-size:24px}p{font-size:16px;line-height:2;color:#495e78}button{padding:13px 26px;color:white;background:#1c3168;border:0;border-radius:12px;font-size:16px;font-weight:bold}</style></head>
<body><main class="box"><div style="font-size:50px">📶</div><h1>ماكو اتصال بالإنترنت</h1><p>متجر مطبعة ذكرى يحتاج اتصال حتى يعرض المنتجات والأسعار الحالية ويستقبل طلباتك. تأكد من الإنترنت وجرّب مرة ثانية.</p><button onclick="location.reload()">إعادة المحاولة</button></main></body></html>`;

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_VERSION)
    .then(cache => cache.addAll(APP_ICONS))
    .then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(keys
      .filter(key => key.startsWith('zikra-pwa-') && key !== CACHE_VERSION)
      .map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  // لا نتدخل أبداً بطلبات Supabase أو صور المنتجات الخارجية.
  if (url.origin !== self.location.origin) return;

  // صفحة المتجر دائماً من الإنترنت لضمان ظهور أحدث كود ومنتجات.
  if (req.mode === 'navigate') {
    event.respondWith(fetch(req).catch(() => new Response(OFFLINE_PAGE, {
      status: 200, headers: {'Content-Type': 'text/html; charset=utf-8'}
    })));
    return;
  }

  // أيقونات التثبيت فقط تعمل من الكاش.
  const iconPaths = APP_ICONS.map(path => new URL(path, self.registration.scope).pathname);
  if (iconPaths.includes(url.pathname)) {
    event.respondWith(caches.match(req).then(cached => cached || fetch(req)));
  }
});
