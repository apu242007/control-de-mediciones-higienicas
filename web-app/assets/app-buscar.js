// ===========================================================================
// Pantalla de busqueda y descarga.
//
// La tabla de resultados SI se reemplaza entera con innerHTML/DOM: no contiene
// ningun input que el usuario pueda estar tipeando. El formulario de filtros,
// en cambio, nunca se repinta.
// ===========================================================================

import { EQUIPOS, CLIENTES, TIPOS_MEDICION } from "./catalogos.js";
import { formatearAR, clasificar } from "./dominio.js";
import { llamar, esDemo, descargarBase64, ErrorApi } from "./api.js";

let resultados = [];
let buscando = false;
let descargando = null;

const $ = (id) => document.getElementById(id);

// --- Avisos --------------------------------------------------------------

function mostrarAviso(clase, titulo, texto) {
  const $a = $("aviso");
  $a.className = `aviso ${clase}`;
  $a.textContent = "";
  if (titulo) {
    const t = document.createElement("div");
    t.className = "titulo";
    t.textContent = titulo;
    $a.appendChild(t);
  }
  $a.appendChild(document.createTextNode(texto));
  $a.hidden = false;
}
function ocultarAviso() { $("aviso").hidden = true; }

// --- Render de la tabla --------------------------------------------------

function pintarResultados() {
  const $cuerpo = $("cuerpo-resultados");
  $cuerpo.textContent = "";

  if (resultados.length === 0) {
    $("tarjeta-resultados").hidden = true;
    $("sin-resultados").hidden = false;
    return;
  }

  $("sin-resultados").hidden = true;
  $("tarjeta-resultados").hidden = false;

  const vencidos = resultados.filter((r) => clasificar(r.fechaVencimiento).clase === "vencido").length;
  const porVencer = resultados.filter((r) => clasificar(r.fechaVencimiento).clase === "porvencer").length;
  let titulo = `Resultados — ${resultados.length} documento${resultados.length === 1 ? "" : "s"}`;
  if (vencidos) titulo += ` · ${vencidos} vencido${vencidos === 1 ? "" : "s"}`;
  if (porVencer) titulo += ` · ${porVencer} por vencer`;
  $("titulo-resultados").textContent = titulo;

  for (const r of resultados) {
    const est = clasificar(r.fechaVencimiento);
    const tr = document.createElement("tr");

    const tdEstado = document.createElement("td");
    const chip = document.createElement("span");
    chip.className = `chip ${est.clase}`;
    chip.textContent = est.etiqueta;
    tdEstado.appendChild(chip);

    const celdas = [
      r.equipo || "—",
      r.tipoMedicion || "—",
      r.cliente || "—",
      formatearAR(r.fechaMedicion),
      formatearAR(r.fechaVencimiento),
    ].map((txt) => {
      const td = document.createElement("td");
      td.textContent = txt;
      return td;
    });

    const tdNombre = document.createElement("td");
    tdNombre.className = "celda-nombre";
    tdNombre.textContent = r.nombre || "—";

    const tdAcciones = document.createElement("td");
    tdAcciones.className = "celda-acciones";

    const btnDescargar = document.createElement("button");
    btnDescargar.type = "button";
    btnDescargar.className = "chico";
    btnDescargar.textContent = "Descargar";
    btnDescargar.addEventListener("click", () => descargar(r, btnDescargar));
    tdAcciones.appendChild(btnDescargar);

    if (r.urlSharePoint) {
      const a = document.createElement("a");
      a.href = r.urlSharePoint;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.textContent = "Abrir";
      tdAcciones.appendChild(a);
    }

    tr.append(tdEstado, ...celdas, tdNombre, tdAcciones);
    $cuerpo.appendChild(tr);
  }
}

// --- Descarga ------------------------------------------------------------

async function descargar(fila, boton) {
  if (descargando) return;
  descargando = fila.rutaRelativa;

  const textoOriginal = boton.textContent;
  boton.disabled = true;
  boton.textContent = "…";
  ocultarAviso();

  try {
    const r = await llamar("descargar", {
      pin: $("pin").value.trim(),
      rutaRelativa: fila.rutaRelativa,
    });
    if (!r?.contenidoBase64) {
      throw new ErrorApi("El servidor no devolvió el contenido del archivo.", 0);
    }
    descargarBase64(r.contenidoBase64, fila.nombre, "application/pdf");
  } catch (e) {
    const err = e instanceof ErrorApi ? e : new ErrorApi(String(e?.message ?? e), 0);
    mostrarAviso("error", "No se pudo descargar", err.message);
  } finally {
    descargando = null;
    boton.disabled = false;
    boton.textContent = textoOriginal;
  }
}

// --- Busqueda ------------------------------------------------------------

async function buscar(evento) {
  evento.preventDefault();
  if (buscando) return;

  const pin = $("pin").value.trim();
  if (!pin) {
    mostrarAviso("warn", "Falta el PIN", "Ingresá el PIN de consulta para buscar.");
    return;
  }

  const desde = $("f-desde").value;
  const hasta = $("f-hasta").value;
  if (desde && hasta && desde > hasta) {
    mostrarAviso("warn", "Rango inválido",
      "La fecha «desde» es posterior a la fecha «hasta».");
    return;
  }

  buscando = true;
  const $btn = $("btn-buscar");
  $btn.disabled = true;
  $btn.textContent = "";
  const spin = document.createElement("span");
  spin.className = "girando";
  $btn.append(spin, document.createTextNode("Buscando…"));
  ocultarAviso();

  try {
    const r = await llamar("listar", {
      pin,
      tipoMedicion: $("f-tipo").value || null,
      equipo: $("f-equipo").value || null,
      cliente: $("f-cliente").value.trim() || null,
      desde: desde ? `${desde}T00:00:00Z` : null,
      hasta: hasta ? `${hasta}T23:59:59Z` : null,
    });

    let filas = Array.isArray(r?.items) ? r.items : [];

    // Estos dos filtros se aplican en el cliente: el estado de vigencia
    // depende de la fecha de hoy, y el texto libre no tiene indice en la
    // biblioteca. Con este volumen de documentos no vale la pena hacerlos
    // en el flow.
    const estado = $("f-estado").value;
    if (estado) filas = filas.filter((f) => clasificar(f.fechaVencimiento).clase === estado);

    const texto = $("f-texto").value.trim().toLowerCase();
    if (texto) {
      filas = filas.filter((f) => String(f.nombre ?? "").toLowerCase().includes(texto));
    }

    filas.sort((a, b) => String(b.fechaMedicion ?? "").localeCompare(String(a.fechaMedicion ?? "")));

    resultados = filas;
    pintarResultados();

    if (r.truncado) {
      mostrarAviso("warn", "Resultados parciales",
        "Hay más documentos de los que se pueden traer de una vez. Acotá los " +
        "filtros (por equipo o por rango de fechas) para verlos todos.");
    }
  } catch (e) {
    const err = e instanceof ErrorApi ? e : new ErrorApi(String(e?.message ?? e), 0);
    if (err.codigo === 401 || err.codigo === 429) $("pin").value = "";
    mostrarAviso("error", "No se pudo buscar", err.message);
    resultados = [];
    $("tarjeta-resultados").hidden = true;
    $("sin-resultados").hidden = true;
  } finally {
    buscando = false;
    $btn.textContent = "Buscar";
    $btn.disabled = false;
  }
}

function limpiar() {
  for (const id of ["f-tipo", "f-equipo", "f-estado"]) $(id).value = "";
  for (const id of ["f-cliente", "f-desde", "f-hasta", "f-texto"]) $(id).value = "";
  resultados = [];
  $("tarjeta-resultados").hidden = true;
  $("sin-resultados").hidden = true;
  ocultarAviso();
}

// --- Arranque ------------------------------------------------------------

export function arrancarBuscador() {
  const $tipo = $("f-tipo");
  for (const t of TIPOS_MEDICION) {
    const o = document.createElement("option");
    o.value = t.valor;
    o.textContent = t.valor;
    $tipo.appendChild(o);
  }

  const $equipo = $("f-equipo");
  for (const e of EQUIPOS) {
    const o = document.createElement("option");
    o.value = e.nombre;
    o.textContent = e.nombre;
    $equipo.appendChild(o);
  }

  const $dl = $("lista-clientes");
  for (const c of [...CLIENTES].sort((a, b) => a.localeCompare(b, "es"))) {
    const o = document.createElement("option");
    o.value = c;
    $dl.appendChild(o);
  }

  $("formulario-busqueda").addEventListener("submit", buscar);
  $("btn-limpiar").addEventListener("click", limpiar);
  $("ver-pin").addEventListener("change", (e) => {
    $("pin").type = e.target.checked ? "text" : "password";
  });

  if (esDemo()) $("aviso-demo").hidden = false;
}
