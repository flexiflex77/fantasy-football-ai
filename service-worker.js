
"use strict";

// Fantasy Football AI – Service Worker
const CACHE_NAME = "fantasy-football-ai-v2";
const CACHE_PREFIX = "fantasy-football-ai-";

// Nur öffentliche, statische App-Dateien zwischenspeichern
const APP_FILES = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png"
];

// Installation
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(APP_FILES);
    })
  );

  self.skipWaiting();
});

// Aktivierung
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then(async (keys) => {
      await Promise.all(
        keys
          .filter((key) =>
            key.startsWith(CACHE_PREFIX) &&
            key !== CACHE_NAME
          )
          .map((key) => caches.delete(key))
      );

      await self.clients.claim();
    })
  );
});

// Nur unsere statischen Dateien behandeln
self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") {
    return;
  }

  const url = new URL(event.request.url);

  // Keine externen Anfragen behandeln
  if (url.origin !== self.location.origin) {
    return;
  }

  // Nur Dateien innerhalb unserer PWA berücksichtigen
  const allowedPaths = APP_FILES.map((file) => {
    return new URL(file, self.registration.scope).pathname;
  });

  if (!allowedPaths.includes(url.pathname)) {
    return;
  }

  // Zuerst Netzwerk, bei Verbindungsfehler Cache
  event.respondWith(
    fetch(event.request).catch(() => {
      return caches.match(event.request);
    })
  );
});

