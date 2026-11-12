const CACHE_NAME = 'sport-performance-v6';
const SHELL = ['/', '/index.html', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(SHELL)).catch(() => {}));
  self.skipWaiting();
});
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k.startsWith('sport-performance-') && k !== CACHE_NAME).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  // Supabase auth, REST and storage are never cached: always use the live secured API.
  if (/\/(rest\/v1|auth\/v1|storage\/v1)\//.test(url.pathname)) return;
  if (req.mode === 'navigate') {
    event.respondWith(fetch(req).then(res => {
      if (res.ok) caches.open(CACHE_NAME).then(c => c.put('/index.html', res.clone()));
      return res;
    }).catch(async () => (await caches.match('/index.html')) || Response.error()));
    return;
  }
  // Network-first for app assets to avoid stale application code after deployment.
  event.respondWith(fetch(req).then(res => {
    if (res.ok && res.type === 'basic') caches.open(CACHE_NAME).then(c => c.put(req, res.clone()));
    return res;
  }).catch(async () => (await caches.match(req)) || Response.error()));
});
