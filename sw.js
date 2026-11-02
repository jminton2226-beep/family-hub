/* Offline-ready static shell. Shared Supabase data still requires connectivity. */
const CACHE = 'family-hub-shell-v2-1';
const ASSETS = ['./', './index.html', './styles.css', './v2.css', './app.js', './config.js', './manifest.webmanifest', './assets/icon.svg', './assets/apple-icon.png'];
self.addEventListener('install', e => e.waitUntil(
  caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting())
));
self.addEventListener('activate', e => e.waitUntil(Promise.all([
  self.clients.claim(),
  caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
])));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET' || new URL(e.request.url).origin !== self.location.origin) return;
  e.respondWith(fetch(e.request).then(response => {
    if (response.ok) {
      const copy = response.clone();
      e.waitUntil(caches.open(CACHE).then(c => c.put(e.request, copy)));
    }
    return response;
  }).catch(async () => {
    const saved = await caches.match(e.request);
    if (saved) return saved;
    if (e.request.mode === 'navigate') return (await caches.match('./index.html')) || Response.error();
    return Response.error();
  }));
});
