// ===========================================================================
// Integridad entre el HTML y el JS.
//
// Estas pruebas no verifican que la pantalla se vea bien — eso hay que mirarlo
// en un navegador. Verifican lo que sí es mecánico y se rompe callado:
//
//   · un getElementById con un id que no existe devuelve null, y la línea
//     siguiente revienta con "Cannot read properties of null". El formulario
//     queda inerte sin un mensaje que explique nada.
//   · un archivo que el service worker precachea y no existe.
//   · un módulo que lee una global en su cuerpo (el bug de los imports que se
//     hoistean, que deja la app en modo demo para siempre).
// ===========================================================================

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), "..");
const APP = join(RAIZ, "web-app");

const leer = (rel) => readFileSync(join(APP, rel), "utf8");

/** Todos los id="..." declarados en un HTML. */
function idsDeclarados(html) {
  return new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
}

/** Todos los id que el JS busca, por $("x") o getElementById("x"). */
function idsUsados(js) {
  const usados = new Set();
  for (const m of js.matchAll(/\$\(\s*["']([^"']+)["']\s*\)/g)) usados.add(m[1]);
  for (const m of js.matchAll(/getElementById\(\s*["']([^"']+)["']\s*\)/g)) usados.add(m[1]);
  return usados;
}

// --- IDs ------------------------------------------------------------------

test("app-carga.js: todos los id que busca existen en index.html", () => {
  const declarados = idsDeclarados(leer("index.html"));
  const usados = idsUsados(leer("assets/app-carga.js"));

  const faltantes = [...usados].filter((id) => !declarados.has(id));
  assert.deepEqual(faltantes, [], `ids que el JS busca y el HTML no declara: ${faltantes.join(", ")}`);
});

test("app-buscar.js: todos los id que busca existen en buscar.html", () => {
  const declarados = idsDeclarados(leer("buscar.html"));
  const usados = idsUsados(leer("assets/app-buscar.js"));

  const faltantes = [...usados].filter((id) => !declarados.has(id));
  assert.deepEqual(faltantes, [], `ids que el JS busca y el HTML no declara: ${faltantes.join(", ")}`);
});

test("los id de cada HTML son únicos", () => {
  for (const pagina of ["index.html", "buscar.html"]) {
    const html = leer(pagina);
    const todos = [...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]);
    const repetidos = todos.filter((id, i) => todos.indexOf(id) !== i);
    assert.deepEqual(repetidos, [], `${pagina} tiene id repetidos: ${repetidos.join(", ")}`);
  }
});

test("cada <label for> apunta a un id que existe", () => {
  for (const pagina of ["index.html", "buscar.html"]) {
    const html = leer(pagina);
    const declarados = idsDeclarados(html);
    const fors = [...html.matchAll(/\bfor="([^"]+)"/g)].map((m) => m[1]);
    const huerfanos = fors.filter((f) => !declarados.has(f));
    assert.deepEqual(huerfanos, [], `${pagina}: for sin destino: ${huerfanos.join(", ")}`);
  }
});

// --- El bug de los módulos ES -------------------------------------------

test("ningún módulo lee una global de configuración en su cuerpo", () => {
  // Los `import` de un módulo ES se evalúan ANTES del cuerpo del <script> que
  // los importa. Un `window.FLOW_URL` puesto ahí todavía no existe cuando el
  // módulo se evalúa, así que la app quedaría en modo demo para siempre, sin
  // un solo error en consola. La config entra por initFlow() y solo por ahí.
  const modulos = [
    "assets/api.js", "assets/dominio.js", "assets/catalogos.js",
    "assets/app-carga.js", "assets/app-buscar.js", "assets/sw-registro.js",
  ];
  for (const m of modulos) {
    const js = leer(m);
    assert.ok(
      !/\bwindow\.(FLOW_URL|APP_KEY|URL_FLOW)\b/.test(js),
      `${m} lee una global de configuración. Tiene que recibirla por parámetro.`
    );
  }
});

test("api.js recibe la configuración por initFlow, no por una constante de módulo", () => {
  const js = leer("assets/api.js");
  assert.match(js, /export function initFlow\(/, "initFlow tiene que existir y exportarse");
  assert.match(js, /export function esDemo\(/, "esDemo tiene que ser una función, no una constante");
  assert.ok(
    !/^export const (DEMO|ES_DEMO)\b/m.test(js),
    "el estado de demo no puede ser una constante de módulo: se evalúa antes de la config"
  );
  assert.match(js, /if \(!_init\)/, "tiene que haber una guarda que avise si falta initFlow");
});

test("las dos páginas llaman a initFlow en el cuerpo del script, después de los imports", () => {
  for (const pagina of ["index.html", "buscar.html"]) {
    const html = leer(pagina);
    const bloque = /<script type="module">([\s\S]*?)<\/script>/.exec(html);
    assert.ok(bloque, `${pagina} tiene que tener un <script type="module">`);

    const cuerpo = bloque[1];
    const posUltimoImport = cuerpo.lastIndexOf("import ");
    const posInitFlow = cuerpo.indexOf("initFlow(");

    assert.ok(posInitFlow > 0, `${pagina} tiene que llamar a initFlow()`);
    assert.ok(
      posInitFlow > posUltimoImport,
      `${pagina}: initFlow() tiene que estar después de los imports`
    );
  }
});

// --- Service worker -----------------------------------------------------

test("todo lo que el service worker precachea existe", () => {
  const sw = leer("assets/sw.js");
  const bloque = /const PRECACHE = \[([\s\S]*?)\]/.exec(sw);
  assert.ok(bloque, "no se encontró la lista PRECACHE");

  const rutas = [...bloque[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  assert.ok(rutas.length > 0, "PRECACHE no puede estar vacío");

  for (const ruta of rutas) {
    if (ruta === "../") continue; // la raíz del sitio, no un archivo
    // Las rutas del SW son relativas a assets/.
    const abs = join(APP, "assets", ruta);
    assert.ok(existsSync(abs), `PRECACHE apunta a un archivo que no existe: ${ruta}`);
  }
});

test("el service worker no cachea las llamadas al flow", () => {
  // Un estado cacheado es peor que un error de red: el usuario cree que el
  // dato que ve es el actual.
  const sw = leer("assets/sw.js");
  assert.match(sw, /req\.method !== "GET"/, "no puede tocar los POST");
  assert.match(sw, /powerplatform|logic\.azure|powerautomate/, "tiene que excluir el host del flow");
});

// --- Config -------------------------------------------------------------

test("config.js tiene los marcadores que el workflow reemplaza", () => {
  const cfg = leer("assets/config.js");
  for (const marcador of ["__URL_FLOW__", "__APP_KEY__"]) {
    assert.ok(cfg.includes(marcador), `falta el marcador ${marcador}`);
  }
});

test("el workflow reemplaza exactamente los marcadores que config.js declara", () => {
  const wf = readFileSync(join(RAIZ, ".github/workflows/deploy-pages.yml"), "utf8");
  for (const marcador of ["__URL_FLOW__", "__APP_KEY__"]) {
    assert.ok(wf.includes(marcador), `el workflow no reemplaza ${marcador}`);
  }
});

test("no hay ninguna URL de flow escrita en el código", () => {
  // Una URL pegada a mano en el código se saltea el mecanismo de secrets y
  // queda en el historial de git para siempre.
  for (const m of ["assets/config.js", "assets/api.js", "assets/app-carga.js", "assets/app-buscar.js"]) {
    const js = leer(m);
    assert.ok(
      !/logic\.azure\.com|powerplatform\.com\/powerautomate/.test(js),
      `${m} tiene una URL de flow escrita directamente. Va por secret.`
    );
  }
});

// --- Catálogos ----------------------------------------------------------

test("los tipos de medición apuntan a las carpetas que existen en SharePoint", async () => {
  const { TIPOS_MEDICION } = await import("../web-app/assets/catalogos.js");
  const carpetas = TIPOS_MEDICION.map((t) => t.carpeta);

  // Los nombres tienen que coincidir EXACTO con las carpetas de la biblioteca,
  // acentos incluidos: el flow las usa para armar la ruta.
  assert.ok(carpetas.includes("Mediciones de luz"));
  assert.ok(carpetas.includes("Medición de Ruido"));

  for (const t of TIPOS_MEDICION) {
    assert.ok(t.valor, "cada tipo necesita un valor");
    assert.ok(t.codigo, `${t.valor} necesita un código de procedimiento`);
    assert.ok(t.etiqueta, `${t.valor} necesita una etiqueta`);
  }
});

test("cada equipo tiene nombre y sigla, sin repetidos", async () => {
  const { EQUIPOS } = await import("../web-app/assets/catalogos.js");
  assert.ok(EQUIPOS.length > 0);

  const nombres = EQUIPOS.map((e) => e.nombre);
  const siglas = EQUIPOS.map((e) => e.sigla);
  assert.equal(new Set(nombres).size, nombres.length, "hay nombres de equipo repetidos");
  assert.equal(new Set(siglas).size, siglas.length, "hay siglas repetidas");

  for (const e of EQUIPOS) {
    assert.ok(e.nombre?.trim(), "un equipo quedó sin nombre");
    assert.ok(e.sigla?.trim(), `${e.nombre} quedó sin sigla`);
  }
});

test("las vigencias tienen una sola opción manual y ninguna con meses negativos", async () => {
  const { VIGENCIAS } = await import("../web-app/assets/catalogos.js");
  const manuales = VIGENCIAS.filter((v) => v.meses === null);
  assert.equal(manuales.length, 1, "tiene que haber exactamente una opción de fecha manual");

  const valores = VIGENCIAS.map((v) => v.valor);
  assert.equal(new Set(valores).size, valores.length, "hay valores de vigencia repetidos");

  for (const v of VIGENCIAS) {
    if (v.meses !== null) {
      assert.ok(Number.isInteger(v.meses) && v.meses > 0, `${v.valor}: los meses tienen que ser un entero positivo`);
    }
    assert.ok(v.etiqueta?.trim(), `${v.valor} quedó sin etiqueta`);
  }
});

test("el tope de tamaño de PDF es mayor que el umbral de aviso", async () => {
  const { PDF_AVISO_MB, PDF_TOPE_MB } = await import("../web-app/assets/catalogos.js");
  assert.ok(PDF_AVISO_MB > 0);
  assert.ok(PDF_TOPE_MB > PDF_AVISO_MB, "el tope tiene que ser mayor que el umbral de aviso");
});

// --- HTML ---------------------------------------------------------------

test("ningún input usa el atributo required", () => {
  // El required nativo dispara el globo del navegador ANTES del onsubmit, así
  // que bloquea la validación propia incluso con preventDefault(). Toda la
  // validación va en JS, con la lista de pendientes a la vista.
  for (const pagina of ["index.html", "buscar.html"]) {
    const html = leer(pagina);
    assert.ok(
      !/<input[^>]*\brequired\b/.test(html),
      `${pagina} usa required: bloquea la validación propia`
    );
  }
});

test("los formularios tienen novalidate", () => {
  for (const pagina of ["index.html", "buscar.html"]) {
    const html = leer(pagina);
    const forms = [...html.matchAll(/<form\b[^>]*>/g)].map((m) => m[0]);
    assert.ok(forms.length > 0, `${pagina} no tiene formulario`);
    for (const f of forms) {
      assert.match(f, /novalidate/, `${pagina}: falta novalidate en ${f}`);
    }
  }
});

test("las páginas declaran viewport-fit=cover para el notch", () => {
  for (const pagina of ["index.html", "buscar.html"]) {
    assert.match(
      leer(pagina), /viewport-fit=cover/,
      `${pagina}: sin esto las variables env(safe-area-inset-*) no existen`
    );
  }
});

test("las páginas declaran el ícono de iOS", () => {
  // iOS ignora los iconos del manifest para "Agregar a inicio". Sin este link
  // el ícono termina siendo una captura de pantalla.
  for (const pagina of ["index.html", "buscar.html"]) {
    assert.match(leer(pagina), /rel="apple-touch-icon"/, `${pagina}: falta apple-touch-icon`);
  }
});

test("el CSS no le saca appearance a las casillas de verificación", () => {
  // Un reset que incluya input[type=checkbox] deja la casilla invisible al
  // marcarse: el estado cambia en JS pero el usuario no ve el tilde y cree
  // que está roto.
  const css = leer("assets/estilos.css");
  const reglas = [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)];
  for (const [, selector, cuerpo] of reglas) {
    if (!/appearance\s*:\s*none/.test(cuerpo)) continue;
    const sel = selector.trim();
    if (!/\binput\b/.test(sel)) continue;
    assert.match(
      sel, /:not\(\[type="checkbox"\]\)/,
      `este selector le saca appearance a las casillas: ${sel}`
    );
  }
});

test("los iconos del manifest existen y declaran tamaños concretos", () => {
  const manifest = JSON.parse(leer("assets/manifest.json"));
  assert.ok(manifest.icons?.length > 0, "el manifest necesita iconos");

  for (const icono of manifest.icons) {
    assert.ok(existsSync(join(APP, "assets", icono.src)), `falta el ícono ${icono.src}`);
    assert.match(icono.sizes, /^\d+x\d+$/, `sizes "${icono.sizes}" tiene que ser concreto, no "any"`);
  }
});
