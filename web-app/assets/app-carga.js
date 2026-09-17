// ===========================================================================
// Pantalla de carga.
//
// El formulario es HTML estatico: el JS solo cablea eventos y toca los nodos
// que cambian. No se repinta con innerHTML mientras el usuario escribe — eso
// le borraria el PIN a medio tipear y le resetearia el scroll.
// ===========================================================================

import {
  EQUIPOS, CLIENTES, TIPOS_MEDICION, VIGENCIAS,
  PDF_AVISO_MB, PDF_TOPE_MB,
} from "./catalogos.js";
import {
  hoyISO, sumarMeses, formatearAR, armarNombre, pendientes,
} from "./dominio.js";
import { llamar, esDemo, archivoABase64, ErrorApi } from "./api.js";

const PERFIL_KEY = "mediciones-perfil-v1";

let archivoPdf = null;
let enviando = false;

const $ = (id) => document.getElementById(id);

// --- Lectura del formulario ---------------------------------------------

function leer() {
  return {
    tipo: $("tipo").value,
    equipo: $("equipo").value,
    cliente: $("cliente").value.trim(),
    fecha: $("fecha").value,
    vigencia: $("vigencia").value,
    vencimiento: $("vencimiento").value,
    pin: $("pin").value.trim(),
  };
}

// --- Refresco de nodos derivados ----------------------------------------

function refrescar() {
  const d = leer();

  // Vencimiento: automatico salvo vigencia manual
  const vig = VIGENCIAS.find((v) => v.valor === d.vigencia);
  const manual = vig && vig.meses === null;
  const $venc = $("vencimiento");

  $venc.readOnly = !manual;
  $("pista-vencimiento").textContent = manual
    ? "Cargá la fecha de vencimiento acordada con el cliente."
    : "Se calcula solo desde la fecha de medición.";

  if (!manual && d.fecha && vig) {
    const calc = sumarMeses(d.fecha, vig.meses);
    if ($venc.value !== calc) $venc.value = calc;
  }

  // Nombre final
  $("nombre-final").value = armarNombre(leer()) || "(faltan datos)";

  // Pendientes
  const faltan = pendientes(leer(), Boolean(archivoPdf));
  const $pend = $("pendientes");
  if (faltan.length === 0) {
    $pend.hidden = true;
  } else {
    $pend.hidden = false;
    const $ul = $("lista-pendientes");
    $ul.textContent = "";
    for (const f of faltan) {
      const li = document.createElement("li");
      li.textContent = f;
      $ul.appendChild(li);
    }
  }
  $("btn-enviar").disabled = faltan.length > 0 || enviando;
}

// --- Archivo -------------------------------------------------------------

function mostrarArchivo() {
  const $zona = $("zona-archivo");
  const $cont = $("zona-contenido");
  const $aviso = $("aviso-tamano");

  $cont.textContent = "";
  const icono = document.createElement("span");
  icono.className = "icono";
  const titulo = document.createElement("span");
  titulo.className = "titulo";
  const detalle = document.createElement("span");
  detalle.className = "detalle";

  if (!archivoPdf) {
    $zona.classList.remove("tiene-archivo");
    icono.textContent = "📄";
    titulo.textContent = "Tocá para elegir el PDF";
    detalle.textContent = "Solo archivos PDF";
    $aviso.hidden = true;
  } else {
    $zona.classList.add("tiene-archivo");
    const mb = archivoPdf.size / (1024 * 1024);
    icono.textContent = "✅";
    titulo.textContent = archivoPdf.name;
    detalle.textContent = `${mb.toFixed(2)} MB · tocá de nuevo para cambiarlo`;

    if (mb > PDF_AVISO_MB) {
      $aviso.hidden = false;
      $aviso.textContent =
        `El PDF pesa ${mb.toFixed(1)} MB. Al enviarse crece cerca de un 33 % más, ` +
        `así que la carga puede tardar bastante o cortarse. Si podés, subí una ` +
        `versión comprimida.`;
    } else {
      $aviso.hidden = true;
    }
  }
  $cont.append(icono, titulo, detalle);
}

function elegirArchivo(archivo) {
  if (!archivo) { archivoPdf = null; mostrarArchivo(); refrescar(); return; }

  const esPdf = archivo.type === "application/pdf" ||
    /\.pdf$/i.test(archivo.name);
  if (!esPdf) {
    mostrarAviso("error", "Archivo inválido", "Solo se aceptan archivos PDF.");
    $("archivo").value = "";
    archivoPdf = null;
    mostrarArchivo(); refrescar();
    return;
  }

  const mb = archivo.size / (1024 * 1024);
  if (mb > PDF_TOPE_MB) {
    mostrarAviso("error", "Archivo demasiado grande",
      `El PDF pesa ${mb.toFixed(1)} MB y el tope es ${PDF_TOPE_MB} MB. ` +
      `Comprimilo o subilo directamente desde SharePoint.`);
    $("archivo").value = "";
    archivoPdf = null;
    mostrarArchivo(); refrescar();
    return;
  }

  ocultarAviso();
  archivoPdf = archivo;
  mostrarArchivo();
  refrescar();
}

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
  $a.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

function ocultarAviso() { $("aviso").hidden = true; }

// --- Perfil (recuerda las ultimas elecciones) ---------------------------

function guardarPerfil(d) {
  try {
    localStorage.setItem(PERFIL_KEY, JSON.stringify({
      tipo: d.tipo, equipo: d.equipo, cliente: d.cliente, vigencia: d.vigencia,
    }));
  } catch { /* modo privado o storage bloqueado: seguir sin perfil */ }
}

function cargarPerfil() {
  try {
    const p = JSON.parse(localStorage.getItem(PERFIL_KEY) ?? "null");
    if (!p) return;
    if (p.tipo) $("tipo").value = p.tipo;
    if (p.equipo) $("equipo").value = p.equipo;
    if (p.cliente) $("cliente").value = p.cliente;
    if (p.vigencia) $("vigencia").value = p.vigencia;
  } catch { /* ignorar */ }
}

// --- Envio ---------------------------------------------------------------

async function enviar(evento) {
  evento.preventDefault();
  if (enviando) return;               // guarda contra el doble tap

  const d = leer();
  if (pendientes(d, Boolean(archivoPdf)).length > 0) { refrescar(); return; }

  const tipo = TIPOS_MEDICION.find((x) => x.valor === d.tipo);
  const equipo = EQUIPOS.find((x) => x.nombre === d.equipo);
  const nombre = armarNombre(d);
  const anio = d.fecha.slice(0, 4);

  enviando = true;
  const $btn = $("btn-enviar");
  $btn.disabled = true;
  $btn.textContent = "";
  const spin = document.createElement("span");
  spin.className = "girando";
  $btn.append(spin, document.createTextNode("Subiendo…"));
  ocultarAviso();

  try {
    const base64 = await archivoABase64(archivoPdf);

    const r = await llamar("subir", {
      pin: d.pin,
      carpetaTipo: tipo.carpeta,
      carpetaEquipo: equipo.nombre,
      carpetaAnio: anio,
      nombreArchivo: nombre,
      contenidoBase64: base64,
      equipo: equipo.nombre,
      cliente: d.cliente,
      tipoMedicion: tipo.valor,
      // Mediodia UTC, no medianoche: a las 00:00 UTC una columna DateTime se
      // muestra el dia anterior en cualquier zona con offset negativo (AR es
      // UTC-3). Mediodia mantiene el dia calendario de -12 a +11.
      fechaMedicion: `${d.fecha}T12:00:00Z`,
      fechaVencimiento: `${d.vencimiento}T12:00:00Z`,
      vigenciaMeses: d.vigencia === "manual" ? null : Number(d.vigencia),
    });

    guardarPerfil(d);
    mostrarExito({
      nombre: r?.nombreArchivo || nombre,
      ruta: `${tipo.carpeta} / ${equipo.nombre} / ${anio}`,
      cliente: d.cliente,
      tipo: tipo.valor,
      fecha: d.fecha,
      vencimiento: d.vencimiento,
      urlSharePoint: r?.urlSharePoint || "",
    });
  } catch (e) {
    const err = e instanceof ErrorApi ? e : new ErrorApi(String(e?.message ?? e), 0);
    // El PIN se limpia solo cuando el rechazo fue del PIN. Ante un error de
    // red no se toca nada: el usuario reintenta sin volver a llenar todo.
    if (err.codigo === 401 || err.codigo === 429) $("pin").value = "";
    mostrarAviso("error", "No se pudo cargar el documento", err.message);
  } finally {
    enviando = false;
    $btn.textContent = "Cargar a SharePoint";
    refrescar();
  }
}

function mostrarExito(info) {
  const $r = $("resumen-exito");
  $r.textContent = "";
  const filas = [
    ["Archivo", info.nombre],
    ["Carpeta", info.ruta],
    ["Equipo", info.ruta.split(" / ")[1] ?? ""],
    ["Cliente", info.cliente],
    ["Tipo", info.tipo],
    ["Medición", formatearAR(info.fecha)],
    ["Vence", formatearAR(info.vencimiento)],
  ];
  for (const [k, v] of filas) {
    if (!v) continue;
    const div = document.createElement("div");
    const a = document.createElement("span");
    a.textContent = k;
    const b = document.createElement("span");
    b.textContent = v;
    div.append(a, b);
    $r.appendChild(div);
  }

  $("formulario").hidden = true;
  $("pantalla-exito").hidden = false;
  ocultarAviso();
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function nuevaCarga() {
  archivoPdf = null;
  $("archivo").value = "";
  $("fecha").value = hoyISO();
  $("pin").value = "";
  $("vencimiento").value = "";
  mostrarArchivo();
  $("pantalla-exito").hidden = true;
  $("formulario").hidden = false;
  refrescar();
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function limpiarTodo() {
  $("formulario").reset();
  archivoPdf = null;
  $("fecha").value = hoyISO();
  $("vigencia").value = "12";
  mostrarArchivo();
  ocultarAviso();
  refrescar();
}

// --- Arranque ------------------------------------------------------------

export function arrancarCarga() {
  // Poblar selects
  const $tipo = $("tipo");
  for (const t of TIPOS_MEDICION) {
    const o = document.createElement("option");
    o.value = t.valor;
    o.textContent = t.valor;
    $tipo.appendChild(o);
  }

  const $equipo = $("equipo");
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

  const $vig = $("vigencia");
  for (const v of VIGENCIAS) {
    const o = document.createElement("option");
    o.value = v.valor;
    o.textContent = v.etiqueta;
    $vig.appendChild(o);
  }
  $vig.value = "12";
  $("fecha").value = hoyISO();
  $("fecha").max = hoyISO();

  cargarPerfil();

  // Eventos
  for (const id of ["tipo", "equipo", "cliente", "fecha", "vigencia", "vencimiento", "pin"]) {
    $(id).addEventListener("input", refrescar);
    $(id).addEventListener("change", refrescar);
  }
  $("archivo").addEventListener("change", (e) => elegirArchivo(e.target.files?.[0] ?? null));
  $("ver-pin").addEventListener("change", (e) => {
    $("pin").type = e.target.checked ? "text" : "password";
  });
  $("formulario").addEventListener("submit", enviar);
  $("btn-limpiar").addEventListener("click", limpiarTodo);
  $("btn-otra").addEventListener("click", nuevaCarga);
  $("btn-ir-buscar").addEventListener("click", () => { location.href = "./buscar.html"; });

  if (esDemo()) $("aviso-demo").hidden = false;

  mostrarArchivo();
  refrescar();
}
