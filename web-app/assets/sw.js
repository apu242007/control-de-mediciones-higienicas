// ===========================================================================
// Service worker.
//
// SUBIR ESTE NUMERO en cada cambio del sitio. Si no, los navegadores que ya
// visitaron la pagina siguen sirviendo la version vieja durante dias.
// ===========================================================================
const CACHE = "mediciones-v2";

const PRECACHE = [
  "../",
  "../index.html",
  "../buscar.html",
  "./estilos.css",
  "./api.js",
  "./config.js",
  "./catalogos.js",
  "./dominio.js",
  "./app-carga.js",
  "./app-buscar.js",
  "./manifest.json",
  "./icono.svg",
];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE)
      .then((c) => c.addAll(PRECACHE))
      .catch(() => { /* un recurso faltante no debe abortar la instalacion */ })
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("message", (e) => {
  if (e.data === "SKIP_WAITING") self.skipWaiting();
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);

  // La Cache API solo acepta http/https. Un chrome-extension:// o blob: que
  // llegue aca hace que cache.put lance TypeError.
  if (url.protocol !== "http:" && url.protocol !== "https:") return;

  // NUNCA cachear las llamadas al flow: un estado cacheado es peor que un
  // error de red, porque el usuario cree que el dato es actual.
  if (url.hostname.includes("powerplatform.com") ||
      url.hostname.includes("logic.azure.com") ||
      url.hostname.includes("powerautomate.com")) return;

  // Solo el propio sitio.
  if (url.origin !== self.location.origin) return;

  // Red primero, cache como respaldo: el sitio es chico y conviene que el
  // usuario vea siempre la version desplegada.
  e.respondWith(
    fetch(req)
      .then((res) => {
        if (res && res.ok) {
          const copia = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copia)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(req).then((r) => r || caches.match("../index.html")))
  );
});
