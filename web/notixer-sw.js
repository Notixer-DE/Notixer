'use strict';

importScripts('notixer-precache.js');

const scope = self.registration.scope;
const prefix = 'notixer-web:' + scope + ':';
const cacheName = prefix + self.precache.version;
const files = new Set(self.precache.files.map(path => new URL(path, scope).href));
const index = new URL('index.html', scope).href;

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(cacheName);
    await cache.addAll([...files].map(url => new Request(url, {cache: 'reload'})));
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names
      .filter(name => name.startsWith(prefix) && name !== cacheName)
      .map(name => caches.delete(name)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', event => {
  const {request} = event;
  if (request.method !== 'GET') return;

  let url = request.url;
  if (request.mode === 'navigate' && (url === scope || url.startsWith(scope + '?'))) {
    url = index;
  }
  if (!files.has(url)) return;
  event.respondWith((async () => {
    const cache = await caches.open(cacheName);
    return await cache.match(url) || fetch(request);
  })());
});
