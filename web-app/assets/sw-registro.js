// ===========================================================================
// Registro del service worker con recarga automatica.
//
// Subir CACHE en sw.js NO alcanza: el worker viejo sigue controlando la
// pestaña hasta que el usuario recarga a mano. Sin esto hay que andar
// pidiendole "Ctrl+Shift+R" cada vez que se despliega un arreglo.
// ===========================================================================

export function registrarSW() {
  if (!("serviceWorker" in navigator)) return;

  let recargando = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (recargando) return;
    recargando = true;
    location.reload();
  });

  window.addEventListener("load", () => {
    navigator.serviceWorker
      .register("./assets/sw.js")
      .then((reg) => {
        if (reg.waiting) reg.waiting.postMessage("SKIP_WAITING");

        reg.addEventListener("updatefound", () => {
          const nuevo = reg.installing;
          if (!nuevo) return;
          nuevo.addEventListener("statechange", () => {
            if (nuevo.state === "installed" && navigator.serviceWorker.controller) {
              nuevo.postMessage("SKIP_WAITING");
            }
          });
        });

        // Los navegadores solo chequean actualizaciones cada 24 h por defecto.
        reg.update().catch(() => {});
      })
      .catch(() => { /* sin SW la app funciona igual, solo pierde el modo offline */ });
  });
}
