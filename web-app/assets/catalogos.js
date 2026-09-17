// ===========================================================================
// CATALOGOS — editar aca y hacer push. No hay build step: el cambio sale en
// el siguiente deploy de GitHub Pages.
//
// IMPORTANTE: si agregas un valor a EQUIPOS, CLIENTES o TIPOS_MEDICION, tenes
// que agregarlo TAMBIEN a la columna Choice correspondiente en SharePoint
// (sharepoint/Setup-Columnas-Mediciones.ps1). SharePoint descarta en silencio
// cualquier valor que no este en la lista de opciones de la columna.
// ===========================================================================

// --- Equipos -------------------------------------------------------------
// `nombre`  = carpeta en SharePoint (tiene que coincidir EXACTO con la que existe)
// `sigla`   = lo que va en el nombre del archivo generado
export const EQUIPOS = [
  { nombre: "Tacker 01", sigla: "TKR 01" },
  { nombre: "Tacker 05", sigla: "TKR 05" },
  { nombre: "Tacker 06", sigla: "TKR 06" },
  { nombre: "Tacker 07", sigla: "TKR 07" },
  { nombre: "Tacker 08", sigla: "TKR 08" },
  { nombre: "Tacker 10", sigla: "TKR 10" },
  { nombre: "Tacker 11", sigla: "TKR 11" },
  { nombre: "Mase 01", sigla: "MASE 01" },
  { nombre: "Mase 02", sigla: "MASE 02" },
  { nombre: "Mase 03", sigla: "MASE 03" },
  { nombre: "Mase 04", sigla: "MASE 04" },
];

// --- Clientes / Operadoras ----------------------------------------------
// TODO JORGE: revisar y dejar SOLO las operadoras reales con las que opera
// Tacker. Estos son valores iniciales para que la app arranque.
export const CLIENTES = [
  "YPF",
  "Pluspetrol",
  "Vista Energy",
  "Pampa Energía",
  "Tecpetrol",
  "Pan American Energy",
  "Shell Argentina",
  "Chevron",
  "Aconcagua Energía",
  "President Petroleum",
  "Petrolera Aconcagua",
  "Capex",
  "Oilstone",
  "Tacker (interno)",
];

// --- Tipos de medicion ---------------------------------------------------
// `carpeta`  = carpeta de primer nivel en SharePoint. EXACTO, con acentos.
// `codigo`   = codigo de procedimiento, va al inicio del nombre de archivo
// `etiqueta` = como se muestra en el nombre de archivo
export const TIPOS_MEDICION = [
  {
    valor: "Iluminación",
    carpeta: "Mediciones de luz",
    codigo: "POSGI001-A7-1",
    etiqueta: "Iluminación",
  },
  {
    valor: "Ruido",
    carpeta: "Medición de Ruido",
    codigo: "POSGI001-A6-2",
    etiqueta: "Ruido",
  },
];

// --- Vigencias -----------------------------------------------------------
// `meses: null` => el usuario carga la fecha de vencimiento a mano.
// Los plazos cortos cubren los clientes que exigen medicion pozo a pozo.
export const VIGENCIAS = [
  { valor: "12", meses: 12, etiqueta: "12 meses (anual — por defecto)" },
  { valor: "6", meses: 6, etiqueta: "6 meses" },
  { valor: "3", meses: 3, etiqueta: "3 meses (pozo a pozo)" },
  { valor: "1", meses: 1, etiqueta: "1 mes" },
  { valor: "manual", meses: null, etiqueta: "Otro — cargar fecha a mano" },
];

// --- Limites de tamaño ---------------------------------------------------
// base64 infla el archivo ~33%, y Power Automate corta a los ~110 s.
// AVISO = se sube pero mostramos advertencia. TOPE = se rechaza en el cliente.
export const PDF_AVISO_MB = 8;
export const PDF_TOPE_MB = 18;

// --- Hitos de alerta -----------------------------------------------------
// Solo informativo en la UI. Los que mandan el mail son los del Flow 2.
export const HITOS_ALERTA_DIAS = [30, 15, 7];
