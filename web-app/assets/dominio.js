// ===========================================================================
// Funciones puras: fechas, nombre de archivo, estado de vigencia.
//
// Estan separadas de las pantallas para poder probarlas sin navegador
// (pruebas/dominio.test.mjs). No tocan el DOM ni la red.
// ===========================================================================

import { EQUIPOS, TIPOS_MEDICION } from "./catalogos.js";

// --- Fechas --------------------------------------------------------------
//
// Toda la aritmetica va sobre los numeros de la cadena YYYY-MM-DD, nunca con
// Date. new Date('2026-01-31') se parsea como medianoche UTC, y en Argentina
// (UTC-3) getDate() devuelve 30: un dia menos, en silencio.

/** Fecha local de hoy como YYYY-MM-DD. */
export function hoyISO(ahora = new Date()) {
  const m = String(ahora.getMonth() + 1).padStart(2, "0");
  const d = String(ahora.getDate()).padStart(2, "0");
  return `${ahora.getFullYear()}-${m}-${d}`;
}

export function diasDelMes(anio, mes) {
  if (mes === 2) {
    const bisiesto = (anio % 4 === 0 && anio % 100 !== 0) || anio % 400 === 0;
    return bisiesto ? 29 : 28;
  }
  return [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mes - 1];
}

/**
 * Suma meses conservando el dia. Si el dia no existe en el mes destino
 * (31 de enero + 1 mes) cae al ultimo dia de ese mes en lugar de desbordarse
 * al mes siguiente, que es lo que haria setMonth().
 */
export function sumarMeses(iso, meses) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso ?? ""));
  if (!m) return "";
  if (!Number.isInteger(meses)) return "";

  const anio0 = Number(m[1]);
  const mes0 = Number(m[2]);
  const dia0 = Number(m[3]);
  if (mes0 < 1 || mes0 > 12 || dia0 < 1 || dia0 > 31) return "";

  const total = anio0 * 12 + (mes0 - 1) + meses;
  const anio = Math.floor(total / 12);
  const mes = (total % 12) + 1;
  const dia = Math.min(dia0, diasDelMes(anio, mes));

  return `${anio}-${String(mes).padStart(2, "0")}-${String(dia).padStart(2, "0")}`;
}

/** Deja solo la parte YYYY-MM-DD de un valor que puede traer hora. */
export function soloFecha(valor) {
  const m = /^(\d{4}-\d{2}-\d{2})/.exec(String(valor ?? ""));
  return m ? m[1] : "";
}

/** YYYY-MM-DD a milisegundos UTC, sin que la zona local corra el dia. */
function aUTC(iso) {
  const [a, m, d] = iso.split("-").map(Number);
  return Date.UTC(a, m - 1, d);
}

/** Dias desde hoy hasta la fecha. Negativo = ya paso. null si no hay fecha. */
export function diasHasta(iso, hoy = hoyISO()) {
  const f = soloFecha(iso);
  if (!f) return null;
  return Math.round((aUTC(f) - aUTC(hoy)) / 86400000);
}

/** YYYY-MM-DD a DD/MM/YYYY. Devuelve '—' si no hay fecha. */
export function formatearAR(iso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso ?? ""));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : "—";
}

// --- Estado de vigencia --------------------------------------------------

/** Clasifica un vencimiento en vencido / porvencer / vigente / sinfecha. */
export function clasificar(vencimiento, hoy = hoyISO()) {
  const d = diasHasta(vencimiento, hoy);
  if (d === null) return { clase: "sinfecha", etiqueta: "Sin fecha", dias: null };
  if (d < 0) return { clase: "vencido", etiqueta: `Vencido hace ${Math.abs(d)} d`, dias: d };
  if (d <= 30) return { clase: "porvencer", etiqueta: `Vence en ${d} d`, dias: d };
  return { clase: "vigente", etiqueta: "Vigente", dias: d };
}

// --- Nombre de archivo ---------------------------------------------------

/**
 * Saca los caracteres que SharePoint rechaza, sin tocar los extremos.
 *
 * Prohibidos por SharePoint:  " * : < > ? / \ |
 * Problematicos en una URL:   # % { } ~ &
 * Los acentos y la ñ si estan permitidos.
 *
 * Se usa para las PARTES del nombre. Un recorte de extremos aca le comeria el
 * punto final a un cliente como "Operadora S.A.", que en el nombre completo
 * queda en el medio y es perfectamente valido.
 */
export function quitarProhibidos(texto) {
  return String(texto ?? "")
    .replace(/["*:<>?/\\|#%{}~&]/g, "")
    .replace(/\.{2,}/g, ".")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Lo anterior, mas el recorte de puntos y espacios en los extremos: SharePoint
 * no acepta un nombre de archivo que empiece o termine asi.
 *
 * Se usa una sola vez, sobre el nombre YA armado.
 */
export function sanearNombre(texto) {
  return quitarProhibidos(texto)
    .replace(/^[.\s]+/, "")
    .replace(/[.\s]+$/, "");
}

/**
 * Arma el nombre con el que se guarda el PDF, siguiendo la convencion que ya
 * se usaba a mano en la biblioteca:
 *
 *   POSGI001-A7-1 Iluminación - TKR 07 - YPF - 2026-09-17.pdf
 *
 * Devuelve '' si falta algun dato.
 */
export function armarNombre({ tipo, equipo, cliente, fecha }) {
  const t = TIPOS_MEDICION.find((x) => x.valor === tipo);
  const e = EQUIPOS.find((x) => x.nombre === equipo);
  if (!t || !e || !soloFecha(fecha)) return "";

  const partes = [
    t.codigo,
    t.etiqueta,
    "-", e.sigla,
    "-", quitarProhibidos(cliente) || "SIN CLIENTE",
    "-", soloFecha(fecha),
  ];
  // Las partes ya vienen sin caracteres prohibidos; el recorte de extremos se
  // aplica una sola vez, aca, sobre el nombre completo.
  const base = sanearNombre(partes.join(" "));
  return base ? `${base}.pdf` : "";
}

// --- Validacion del formulario ------------------------------------------

/**
 * Devuelve la lista de lo que falta para poder enviar. Vacia = se puede enviar.
 *
 * Se devuelven textos listos para mostrar, no codigos: la pantalla los lista
 * tal cual, asi el usuario ve exactamente que le falta en lugar de encontrarse
 * un boton deshabilitado sin explicacion.
 */
export function pendientes(datos, tieneArchivo, hoy = hoyISO()) {
  const p = [];
  if (!datos.tipo) p.push("Tipo de medición");
  if (!datos.equipo) p.push("Equipo");
  if (!datos.cliente) p.push("Cliente / Operadora");

  if (!datos.fecha) {
    p.push("Fecha de la medición");
  } else if (datos.fecha > hoy) {
    p.push("La fecha de medición no puede ser futura");
  }

  if (!datos.vencimiento) {
    p.push("Fecha de vencimiento");
  } else if (datos.fecha && datos.vencimiento <= datos.fecha) {
    p.push("El vencimiento tiene que ser posterior a la fecha de medición");
  }

  if (!tieneArchivo) p.push("Archivo PDF");
  if (!datos.pin) p.push("PIN de carga");
  return p;
}
