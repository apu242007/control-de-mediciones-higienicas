// ===========================================================================
// Pruebas de las funciones puras. Se corren sin navegador ni dependencias:
//
//   npm test        (o: node --test)
//
// Sin argumento de ruta: node --test descubre por patron y anda igual en
// Node 18, 20 y 22. Pasarle 'pruebas/' rompe en Node 22, que lo trata como un
// modulo a ejecutar en vez de un directorio a escanear.
//
// Cubren lo deterministico y propenso a error de borde: aritmetica de fechas,
// saneado de nombres de archivo y la validacion del formulario. El flow y
// SharePoint no se pueden probar aca — para eso esta la prueba manual con un
// PDF real que describe el README.
// ===========================================================================

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  hoyISO, diasDelMes, sumarMeses, soloFecha, diasHasta, formatearAR,
  clasificar, quitarProhibidos, sanearNombre, armarNombre, pendientes,
} from "../web-app/assets/dominio.js";

// --- diasDelMes ----------------------------------------------------------

test("diasDelMes: meses normales", () => {
  assert.equal(diasDelMes(2026, 1), 31);
  assert.equal(diasDelMes(2026, 4), 30);
  assert.equal(diasDelMes(2026, 12), 31);
});

test("diasDelMes: febrero y años bisiestos", () => {
  assert.equal(diasDelMes(2026, 2), 28);
  assert.equal(diasDelMes(2028, 2), 29, "2028 es bisiesto");
  assert.equal(diasDelMes(2100, 2), 28, "2100 NO es bisiesto: divisible por 100");
  assert.equal(diasDelMes(2000, 2), 29, "2000 SI es bisiesto: divisible por 400");
});

// --- sumarMeses ----------------------------------------------------------

test("sumarMeses: caso normal", () => {
  assert.equal(sumarMeses("2026-09-17", 12), "2027-09-17");
  assert.equal(sumarMeses("2026-09-17", 6), "2027-03-17");
  assert.equal(sumarMeses("2026-09-17", 3), "2026-12-17");
  assert.equal(sumarMeses("2026-09-17", 1), "2026-10-17");
});

test("sumarMeses: cruce de año", () => {
  assert.equal(sumarMeses("2026-12-31", 1), "2027-01-31");
  assert.equal(sumarMeses("2026-11-30", 3), "2027-02-28");
});

test("sumarMeses: el día no se desborda al mes siguiente", () => {
  // Con setMonth() ingenuo, 31/01 + 1 mes daría 03/03. Tiene que dar 28/02.
  assert.equal(sumarMeses("2026-01-31", 1), "2026-02-28");
  assert.equal(sumarMeses("2028-01-31", 1), "2028-02-29", "2028 es bisiesto");
  assert.equal(sumarMeses("2026-03-31", 1), "2026-04-30");
  assert.equal(sumarMeses("2026-05-31", 1), "2026-06-30");
  assert.equal(sumarMeses("2026-08-31", 6), "2027-02-28");
});

test("sumarMeses: 12 meses desde un 29 de febrero", () => {
  assert.equal(sumarMeses("2028-02-29", 12), "2029-02-28");
});

test("sumarMeses: entradas inválidas devuelven cadena vacía", () => {
  assert.equal(sumarMeses("", 12), "");
  assert.equal(sumarMeses(null, 12), "");
  assert.equal(sumarMeses("17/09/2026", 12), "", "no acepta formato DD/MM/YYYY");
  assert.equal(sumarMeses("2026-9-17", 12), "", "exige dos dígitos en mes y día");
  assert.equal(sumarMeses("2026-13-01", 12), "", "mes 13 no existe");
  assert.equal(sumarMeses("2026-09-17", 1.5), "", "los meses tienen que ser entero");
});

// --- soloFecha -----------------------------------------------------------

test("soloFecha: recorta la hora", () => {
  assert.equal(soloFecha("2026-09-17T12:00:00Z"), "2026-09-17");
  assert.equal(soloFecha("2026-09-17"), "2026-09-17");
  assert.equal(soloFecha(""), "");
  assert.equal(soloFecha(null), "");
  assert.equal(soloFecha("sin fecha"), "");
});

// --- diasHasta -----------------------------------------------------------

test("diasHasta: cuenta días sin que la zona horaria corra el resultado", () => {
  assert.equal(diasHasta("2026-09-17", "2026-09-17"), 0);
  assert.equal(diasHasta("2026-09-18", "2026-09-17"), 1);
  assert.equal(diasHasta("2026-09-16", "2026-09-17"), -1);
  assert.equal(diasHasta("2026-10-17", "2026-09-17"), 30);
  assert.equal(diasHasta("2027-09-17", "2026-09-17"), 365);
});

test("diasHasta: funciona con valores que traen hora", () => {
  assert.equal(diasHasta("2026-09-20T12:00:00Z", "2026-09-17"), 3);
});

test("diasHasta: sin fecha devuelve null, no 0", () => {
  // Devolver 0 haría que un documento sin vencimiento apareciera como
  // "vence hoy", que es justo el aviso que no queremos dar.
  assert.equal(diasHasta("", "2026-09-17"), null);
  assert.equal(diasHasta(null, "2026-09-17"), null);
});

test("diasHasta: cruza el cambio de horario de verano sin perder un día", () => {
  // En el hemisferio norte el DST cae en marzo y noviembre. Con aritmetica
  // sobre Date local, un rango que lo cruza puede dar 27,96 dias y redondear mal.
  assert.equal(diasHasta("2026-04-01", "2026-03-01"), 31);
  assert.equal(diasHasta("2026-12-01", "2026-11-01"), 30);
});

// --- formatearAR ---------------------------------------------------------

test("formatearAR: pasa a DD/MM/YYYY", () => {
  assert.equal(formatearAR("2026-09-17"), "17/09/2026");
  assert.equal(formatearAR("2026-09-17T12:00:00Z"), "17/09/2026");
  assert.equal(formatearAR(""), "—");
  assert.equal(formatearAR(null), "—");
});

// --- clasificar ----------------------------------------------------------

test("clasificar: vigente cuando falta más de un mes", () => {
  const r = clasificar("2026-12-31", "2026-09-17");
  assert.equal(r.clase, "vigente");
  assert.equal(r.etiqueta, "Vigente");
});

test("clasificar: por vencer dentro de los 30 días", () => {
  assert.equal(clasificar("2026-10-17", "2026-09-17").clase, "porvencer", "exactamente 30 días");
  assert.equal(clasificar("2026-09-24", "2026-09-17").clase, "porvencer");
  assert.equal(clasificar("2026-09-17", "2026-09-17").clase, "porvencer", "vence hoy");
});

test("clasificar: el día 31 ya es vigente", () => {
  assert.equal(clasificar("2026-10-18", "2026-09-17").clase, "vigente");
});

test("clasificar: vencido", () => {
  const r = clasificar("2026-09-10", "2026-09-17");
  assert.equal(r.clase, "vencido");
  assert.equal(r.etiqueta, "Vencido hace 7 d");
});

test("clasificar: sin fecha no es ni vencido ni vigente", () => {
  const r = clasificar("", "2026-09-17");
  assert.equal(r.clase, "sinfecha");
  assert.equal(r.dias, null);
});

// --- sanearNombre --------------------------------------------------------

test("sanearNombre: saca los caracteres que SharePoint rechaza", () => {
  assert.equal(sanearNombre('a"b*c:d<e>f?g/h\\i|j'), "abcdefghij");
  assert.equal(sanearNombre("a#b%c{d}e~f&g"), "abcdefg");
});

test("sanearNombre: conserva los acentos y la ñ", () => {
  assert.equal(sanearNombre("Iluminación Año Ruído"), "Iluminación Año Ruído");
});

test("sanearNombre: colapsa espacios y recorta los extremos", () => {
  assert.equal(sanearNombre("  hola   mundo  "), "hola mundo");
  assert.equal(sanearNombre("...hola..."), "hola");
  assert.equal(sanearNombre(" . hola . "), "hola");
});

test("sanearNombre: colapsa los puntos seguidos", () => {
  // Dos de los archivos del historial tienen '..pdf' por un doble punto.
  assert.equal(sanearNombre("archivo..nombre"), "archivo.nombre");
});

test("sanearNombre: entradas vacías no explotan", () => {
  assert.equal(sanearNombre(""), "");
  assert.equal(sanearNombre(null), "");
  assert.equal(sanearNombre(undefined), "");
});

// --- quitarProhibidos ----------------------------------------------------

test("quitarProhibidos: conserva el punto final de una razón social", () => {
  // Es la diferencia con sanearNombre: acá el punto es interno al nombre
  // completo, así que recortarlo estaría mal.
  assert.equal(quitarProhibidos("Operadora S.A."), "Operadora S.A.");
  assert.equal(quitarProhibidos("Oper/adora <S.A.>"), "Operadora S.A.");
});

test("quitarProhibidos: igual saca los caracteres prohibidos", () => {
  assert.equal(quitarProhibidos('a"b*c:d<e>f?g/h\\i|j'), "abcdefghij");
  assert.equal(quitarProhibidos("  hola   mundo  "), "hola mundo");
});

test("quitarProhibidos vs sanearNombre: se diferencian en los extremos", () => {
  assert.equal(quitarProhibidos("S.A."), "S.A.");
  assert.equal(sanearNombre("S.A."), "S.A", "sanearNombre sí recorta el punto final");
});

// --- armarNombre ---------------------------------------------------------

test("armarNombre: iluminación", () => {
  assert.equal(
    armarNombre({ tipo: "Iluminación", equipo: "Tacker 07", cliente: "YPF", fecha: "2026-09-17" }),
    "POSGI001-A7-1 Iluminación - TKR 07 - YPF - 2026-09-17.pdf"
  );
});

test("armarNombre: ruido usa otro código de procedimiento", () => {
  assert.equal(
    armarNombre({ tipo: "Ruido", equipo: "Mase 03", cliente: "Pluspetrol", fecha: "2026-01-31" }),
    "POSGI001-A6-2 Ruido - MASE 03 - Pluspetrol - 2026-01-31.pdf"
  );
});

test("armarNombre: sanea el cliente escrito a mano", () => {
  const n = armarNombre({
    tipo: "Ruido", equipo: "Tacker 11",
    cliente: "Oper/adora <S.A.>", fecha: "2026-05-02",
  });
  assert.equal(n, "POSGI001-A6-2 Ruido - TKR 11 - Operadora S.A. - 2026-05-02.pdf");
  assert.ok(!/[/<>]/.test(n), "no puede quedar ningún carácter prohibido");
});

test("armarNombre: cliente vacío no deja el nombre a medias", () => {
  assert.equal(
    armarNombre({ tipo: "Ruido", equipo: "Tacker 01", cliente: "", fecha: "2026-05-02" }),
    "POSGI001-A6-2 Ruido - TKR 01 - SIN CLIENTE - 2026-05-02.pdf"
  );
});

test("armarNombre: acepta una fecha con hora", () => {
  assert.equal(
    armarNombre({ tipo: "Ruido", equipo: "Tacker 01", cliente: "YPF", fecha: "2026-05-02T12:00:00Z" }),
    "POSGI001-A6-2 Ruido - TKR 01 - YPF - 2026-05-02.pdf"
  );
});

test("armarNombre: si falta un dato devuelve cadena vacía, no un nombre roto", () => {
  assert.equal(armarNombre({ tipo: "", equipo: "Tacker 07", cliente: "YPF", fecha: "2026-09-17" }), "");
  assert.equal(armarNombre({ tipo: "Ruido", equipo: "", cliente: "YPF", fecha: "2026-09-17" }), "");
  assert.equal(armarNombre({ tipo: "Ruido", equipo: "Tacker 07", cliente: "YPF", fecha: "" }), "");
  assert.equal(armarNombre({ tipo: "Inexistente", equipo: "Tacker 07", cliente: "YPF", fecha: "2026-09-17" }), "");
  assert.equal(armarNombre({ tipo: "Ruido", equipo: "Tacker 99", cliente: "YPF", fecha: "2026-09-17" }), "");
});

// --- pendientes ----------------------------------------------------------

const COMPLETO = {
  tipo: "Ruido",
  equipo: "Tacker 07",
  cliente: "YPF",
  fecha: "2026-09-10",
  vencimiento: "2027-09-10",
  pin: "1234",
};

test("pendientes: un formulario completo no tiene nada pendiente", () => {
  assert.deepEqual(pendientes(COMPLETO, true, "2026-09-17"), []);
});

test("pendientes: nombra cada campo que falta", () => {
  const p = pendientes({ ...COMPLETO, tipo: "", cliente: "" }, true, "2026-09-17");
  assert.ok(p.includes("Tipo de medición"));
  assert.ok(p.includes("Cliente / Operadora"));
  assert.equal(p.length, 2);
});

test("pendientes: sin archivo no se puede enviar", () => {
  const p = pendientes(COMPLETO, false, "2026-09-17");
  assert.deepEqual(p, ["Archivo PDF"]);
});

test("pendientes: sin PIN no se puede enviar", () => {
  const p = pendientes({ ...COMPLETO, pin: "" }, true, "2026-09-17");
  assert.deepEqual(p, ["PIN de carga"]);
});

test("pendientes: rechaza una fecha de medición futura", () => {
  const p = pendientes({ ...COMPLETO, fecha: "2026-09-20" }, true, "2026-09-17");
  assert.ok(p.some((x) => x.includes("no puede ser futura")));
});

test("pendientes: la fecha de hoy sí se acepta", () => {
  const p = pendientes(
    { ...COMPLETO, fecha: "2026-09-17", vencimiento: "2027-09-17" },
    true, "2026-09-17"
  );
  assert.deepEqual(p, []);
});

test("pendientes: el vencimiento tiene que ser posterior a la medición", () => {
  const anterior = pendientes(
    { ...COMPLETO, fecha: "2026-09-10", vencimiento: "2026-09-01" },
    true, "2026-09-17"
  );
  assert.ok(anterior.some((x) => x.includes("posterior")));

  const mismoDia = pendientes(
    { ...COMPLETO, fecha: "2026-09-10", vencimiento: "2026-09-10" },
    true, "2026-09-17"
  );
  assert.ok(mismoDia.some((x) => x.includes("posterior")), "el mismo día tampoco sirve");
});

test("pendientes: un formulario vacío lista todo, sin repetir", () => {
  const vacio = { tipo: "", equipo: "", cliente: "", fecha: "", vencimiento: "", pin: "" };
  const p = pendientes(vacio, false, "2026-09-17");
  // tipo, equipo, cliente, fecha, vencimiento, archivo, PIN
  assert.equal(p.length, 7);
  assert.equal(new Set(p).size, 7, "no puede haber entradas duplicadas");
});

// --- hoyISO --------------------------------------------------------------

test("hoyISO: formato con ceros a la izquierda", () => {
  assert.equal(hoyISO(new Date(2026, 0, 5)), "2026-01-05");
  assert.equal(hoyISO(new Date(2026, 11, 31)), "2026-12-31");
  assert.match(hoyISO(), /^\d{4}-\d{2}-\d{2}$/);
});

// --- Integración: el cálculo que hace la pantalla -----------------------

test("integración: vigencia de 12 meses da un vencimiento vigente", () => {
  const medicion = "2026-09-17";
  const venc = sumarMeses(medicion, 12);
  assert.equal(venc, "2027-09-17");
  assert.equal(clasificar(venc, medicion).clase, "vigente");
  assert.deepEqual(
    pendientes({ ...COMPLETO, fecha: medicion, vencimiento: venc }, true, medicion),
    []
  );
});

test("integración: vigencia de 1 mes queda 'por vencer' desde el día uno", () => {
  // Es lo esperado: un plazo de 30 días entra entero en la ventana de aviso.
  const medicion = "2026-09-17";
  const venc = sumarMeses(medicion, 1);
  assert.equal(clasificar(venc, medicion).clase, "porvencer");
});

test("integración: una medición de hace 13 meses figura vencida", () => {
  const medicion = "2025-08-17";
  const venc = sumarMeses(medicion, 12);
  const r = clasificar(venc, "2026-09-17");
  assert.equal(r.clase, "vencido");
  assert.equal(r.dias, -31);
});
