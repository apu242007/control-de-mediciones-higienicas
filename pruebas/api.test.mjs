// ===========================================================================
// Pruebas del cliente del flow.
//
// Lo que se verifica acá es el contrato de configuración. Es el que produce el
// peor bug posible de esta arquitectura: si el módulo leyera la URL de una
// global en su cuerpo, los `import` (que se hoistean) harían que la global
// todavía no existiera, el módulo quedaría en modo demo PARA SIEMPRE, y no
// habría un solo error en consola. La app validaría todo y no guardaría nada.
//
// Correr este arnés bajo Node es justamente lo que lo detecta: acá las globales
// del navegador no existen nunca.
// ===========================================================================

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { initFlow, esDemo, llamar, ErrorApi } from "../web-app/assets/api.js";

const URL_REAL = "https://prod-00.brazilsouth.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?sig=xyz";

/** Reemplaza fetch por uno que devuelve lo indicado y registra la llamada. */
function fetchFalso({ status = 200, cuerpo = "{}", explota = false } = {}) {
  const registro = { llamadas: [] };
  globalThis.fetch = async (url, opciones) => {
    registro.llamadas.push({ url, opciones });
    if (explota) throw new TypeError("Failed to fetch");
    return {
      ok: status >= 200 && status < 300,
      status,
      text: async () => cuerpo,
    };
  };
  return registro;
}

beforeEach(() => {
  initFlow("", "");
});

// --- Guarda de inicialización -------------------------------------------

test("esDemo: sin configurar, está en modo demo", () => {
  assert.equal(esDemo(), true);
});

test("esDemo: los marcadores sin reemplazar cuentan como modo demo", () => {
  // Si el workflow no sustituyó config.js, el sitio publicado tiene que
  // avisarlo, no intentar llamar a una URL que no existe.
  initFlow("__URL_FLOW__", "__APP_KEY__");
  assert.equal(esDemo(), true);

  initFlow("REEMPLAZAR_CON_LA_URL", "");
  assert.equal(esDemo(), true);
});

test("esDemo: con una URL real, no está en modo demo", () => {
  initFlow(URL_REAL, "clave");
  assert.equal(esDemo(), false);
});

test("esDemo: recorta los espacios (un copiado con salto de línea no rompe)", () => {
  initFlow(`  ${URL_REAL}\n`, "  clave  ");
  assert.equal(esDemo(), false);
});

test("esDemo: tolera valores que no son texto", () => {
  initFlow(null, undefined);
  assert.equal(esDemo(), true);
  initFlow(123, {});
  assert.equal(esDemo(), true);
});

test("llamar: en modo demo no envía nada y lo dice", async () => {
  initFlow("", "");
  fetchFalso();
  await assert.rejects(
    () => llamar("subir", { pin: "1234" }),
    (e) => {
      assert.ok(e instanceof ErrorApi);
      assert.match(e.message, /demo/i);
      return true;
    }
  );
});

// --- Forma del pedido ----------------------------------------------------

test("llamar: manda Content-Type application/json", async () => {
  // Con text/plain, Power Automate trata el cuerpo como una cadena y
  // triggerBody()?['x'] falla con "Property selection is not supported on
  // values of type 'String'".
  initFlow(URL_REAL, "clave");
  const reg = fetchFalso({ cuerpo: '{"ok":true}' });

  await llamar("listar", { pin: "1234" });

  const { opciones } = reg.llamadas[0];
  assert.equal(opciones.method, "POST");
  assert.equal(opciones.headers["Content-Type"], "application/json");
});

test("llamar: incluye la clave de app cuando está configurada", async () => {
  initFlow(URL_REAL, "mi-clave");
  const reg = fetchFalso({ cuerpo: '{"ok":true}' });

  await llamar("listar", { pin: "1234" });

  assert.equal(reg.llamadas[0].opciones.headers["x-app-key"], "mi-clave");
});

test("llamar: sin clave configurada no manda la cabecera vacía", async () => {
  initFlow(URL_REAL, "");
  const reg = fetchFalso({ cuerpo: '{"ok":true}' });

  await llamar("listar", { pin: "1234" });

  assert.equal("x-app-key" in reg.llamadas[0].opciones.headers, false);
});

test("llamar: la acción y los datos van en el cuerpo", async () => {
  initFlow(URL_REAL, "clave");
  const reg = fetchFalso({ cuerpo: '{"ok":true}' });

  await llamar("subir", { pin: "9876", nombreArchivo: "x.pdf" });

  const enviado = JSON.parse(reg.llamadas[0].opciones.body);
  assert.equal(enviado.accion, "subir");
  assert.equal(enviado.pin, "9876");
  assert.equal(enviado.nombreArchivo, "x.pdf");
});

// --- Respuestas ----------------------------------------------------------

test("llamar: devuelve el JSON del flow en el caso feliz", async () => {
  initFlow(URL_REAL, "clave");
  fetchFalso({ cuerpo: '{"ok":true,"items":[{"nombre":"a.pdf"}]}' });

  const r = await llamar("listar", { pin: "1234" });
  assert.equal(r.ok, true);
  assert.equal(r.items[0].nombre, "a.pdf");
});

test("llamar: un 200 SIN cuerpo se reporta como error, no como éxito vacío", async () => {
  // Una rama del flow sin acción Respuesta devuelve 202 sin cuerpo. Si eso se
  // leyera como éxito, la pantalla mostraría "no hay nada" en lugar de un
  // error: el modo de falla más caro de diagnosticar, porque no parece falla.
  initFlow(URL_REAL, "clave");
  fetchFalso({ status: 202, cuerpo: "" });

  await assert.rejects(
    () => llamar("listar", { pin: "1234" }),
    (e) => {
      assert.ok(e instanceof ErrorApi);
      assert.match(e.message, /sin contenido/i);
      return true;
    }
  );
});

test("llamar: traduce los códigos de error a mensajes en castellano", async () => {
  initFlow(URL_REAL, "clave");
  const casos = [
    [401, /PIN incorrecto/i],
    [429, /bloqueado/i],
    [413, /demasiado grande/i],
    [502, /tardó demasiado/i],
  ];
  for (const [codigo, patron] of casos) {
    fetchFalso({ status: codigo, cuerpo: "{}" });
    await assert.rejects(
      () => llamar("subir", { pin: "0000" }),
      (e) => {
        assert.equal(e.codigo, codigo, `código ${codigo}`);
        assert.match(e.message, patron, `mensaje para ${codigo}`);
        return true;
      }
    );
  }
});

test("llamar: si el flow manda su propio mensaje de error, se usa ese", async () => {
  initFlow(URL_REAL, "clave");
  fetchFalso({ status: 409, cuerpo: '{"error":"Ese documento ya fue cargado."}' });

  await assert.rejects(
    () => llamar("subir", { pin: "1234" }),
    (e) => {
      assert.equal(e.message, "Ese documento ya fue cargado.");
      return true;
    }
  );
});

test("llamar: un fallo de red da mensaje de red, no un error crudo", async () => {
  initFlow(URL_REAL, "clave");
  fetchFalso({ explota: true });

  await assert.rejects(
    () => llamar("listar", { pin: "1234" }),
    (e) => {
      assert.equal(e.codigo, 0);
      assert.match(e.message, /Sin conexión/i);
      return true;
    }
  );
});

test("llamar: un error 500 con cuerpo que no es JSON no rompe el cliente", async () => {
  initFlow(URL_REAL, "clave");
  fetchFalso({ status: 500, cuerpo: "<html>Internal Server Error</html>" });

  await assert.rejects(
    () => llamar("listar", { pin: "1234" }),
    (e) => {
      assert.equal(e.codigo, 500);
      assert.match(e.message, /HTTP 500/);
      return true;
    }
  );
});
