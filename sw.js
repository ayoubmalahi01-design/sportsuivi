const C='ss6';
self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(
    caches.open(C).then(c => c.addAll(['./', 'index.html', 'config.js', 'manifest.webmanifest'])).catch(() => console.log('Cache addAll completed with warnings'))
  );
});
self.addEventListener('activate', e => {
  e.waitUntil(self.clients.claim());
});
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET' || new URL(e.request.url).origin !== location.origin) return;
  e.respondWith(
    caches.match(e.request).then(r => r || fetch(e.request).then(f => {
      const k = f.clone();
      caches.open(C).then(c => c.put(e.request, k)).catch(() => console.log('Fetch cache store error', e.request.url));
      return f;
    }))
  );
});