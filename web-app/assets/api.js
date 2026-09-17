// ===========================================================================
// Cliente del flow de Power Automate.
//
// REGLA DURA: este modulo NO lee ninguna global en su cuerpo. Los `import` de
// un modulo ES se hoistean — se evaluan ANTES del cuerpo del <script> que los
// importa — asi que cualquier `window.X` seteado ahi todavia no existe cuando
// este archivo se evalua. Leerlo aca dejaria la app en modo demo para siempre,
// sin un solo error en consola.
//
// La config entra por initFlow(), y solo por ahi.
// ===========================================================================

let _url = "";
let _key = "";
let _init = false;

/** Configura el cliente. Llamar UNA vez, desde el cuerpo del <script type="module">. */
export function initFlow(url, key) {
  _url = typeof url === "string" ? url.trim() : "";
  _key = typeof key === "string" ? key.trim() : "";
  _init = true;
}

/** true cuando no hay URL real configurada (dev local, o el CI no sustituyo el placeholder). */
export function esDemo() {
  return !_url || _url.indexOf("__URL_FLOW") === 0 || _url.indexOf("REEMPLAZAR") >= 0;
}

class ErrorApi extends Error {
  constructor(mensaje, codigo, detalle) {
    super(mensaje);
    this.name = "ErrorApi";
    this.codigo = codigo ?? 0;
    this.detalle = detalle ?? null;
  }
}
export { ErrorApi };

function mensajePorCodigo(codigo, delServidor) {
  if (delServidor) return delServidor;
  switch (codigo) {
    case 401:
      return "PIN incorrecto.";
    case 403:
      return "No tenés permiso para esta acción.";
    case 409:
      return "Ya existe un documento igual. Revisá el buscador antes de volver a subir.";
    case 413:
      return "El archivo es demasiado grande para el envío.";
    case 429:
      return "Demasiados intentos fallidos. El acceso quedó bloqueado por unos minutos.";
    case 502:
    case 504:
      return "El servidor tardó demasiado. Si el PDF es grande, probá con uno más liviano.";
    case 0:
      return "Sin conexión con el servidor. Revisá la red y volvé a intentar.";
    default:
      return `Error del servidor (HTTP ${codigo}).`;
  }
}

/**
 * Llama al flow. Toda accion pasa por aca.
 * @param {string} accion  'subir' | 'listar' | 'descargar'
 * @param {object} datos   payload propio de la accion (incluye el pin)
 */
export async function llamar(accion, datos) {
  if (!_init) {
    throw new ErrorApi("Falta llamar a initFlow() antes de usar la API.", 0);
  }
  if (esDemo()) {
    throw new ErrorApi(
      "Modo demo: falta configurar la URL del flow. Nada se envió.",
      0
    );
  }

  const cuerpo = JSON.stringify({ accion, ...datos });

  // Content-Type application/json es obligatorio. Con text/plain, Power
  // Automate trata el body como String y triggerBody()?['x'] falla con
  // "Property selection is not supported on values of type 'String'".
  const cabeceras = { "Content-Type": "application/json" };
  if (_key) cabeceras["x-app-key"] = _key;

  let res;
  try {
    res = await fetch(_url, { method: "POST", headers: cabeceras, body: cuerpo });
  } catch (e) {
    throw new ErrorApi(mensajePorCodigo(0), 0, String(e));
  }

  const texto = await res.text();
  let json = null;
  if (texto) {
    try {
      json = JSON.parse(texto);
    } catch {
      /* el flow devolvio algo que no es JSON; se reporta por codigo */
    }
  }

  if (!res.ok) {
    throw new ErrorApi(mensajePorCodigo(res.status, json?.error), res.status, json);
  }

  // Un camino del flow sin accion Respuesta devuelve 202 sin cuerpo. El
  // cliente lo leeria como exito con datos vacios — el modo de falla mas
  // caro de diagnosticar, porque no parece una falla. Lo hacemos ruidoso.
  if (json === null) {
    throw new ErrorApi(
      "El servidor respondió sin contenido. Puede que la operación haya quedado a medias: verificá en el buscador antes de reintentar.",
      res.status
    );
  }

  return json;
}

/** Lee un File como base64 pelado, sin el prefijo `data:...;base64,`. */
export function archivoABase64(archivo) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onerror = () => reject(new Error("No se pudo leer el archivo."));
    fr.onload = () => {
      const r = String(fr.result ?? "");
      const coma = r.indexOf(",");
      resolve(coma >= 0 ? r.slice(coma + 1) : r);
    };
    fr.readAsDataURL(archivo);
  });
}

/** Dispara la descarga de un base64 como archivo, sin pasar por SharePoint. */
export function descargarBase64(base64, nombre, tipo) {
  const bin = atob(base64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const blob = new Blob([bytes], { type: tipo || "application/pdf" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = nombre || "documento.pdf";
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Revocar en el siguiente tick: revocar sincronicamente cancela la descarga
  // en algunos navegadores.
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}
