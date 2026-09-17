// ===========================================================================
// CONFIG — los valores reales los inyecta GitHub Actions al desplegar.
//
// Los placeholders de abajo se reemplazan en .github/workflows/deploy-pages.yml
// con el contenido de los secrets del repositorio. Si abris este archivo desde
// GitHub vas a ver los placeholders, no la URL: eso es lo esperado.
//
// AVISO DE SEGURIDAD: una vez desplegados, estos valores son PUBLICOS — viajan
// dentro del JavaScript que descarga el navegador. Guardarlos como secrets solo
// los mantiene fuera del codigo fuente, no fuera del sitio publicado.
//
//   · FLOW_URL  es publica por diseño: el navegador tiene que poder llamarla.
//   · APP_KEY   NO es una contraseña. Es un freno para bots, nada mas.
//   · El control de acceso real es el PIN, que se valida DENTRO del flow
//     contra SharePoint, con contador de intentos y bloqueo temporal.
// ===========================================================================

export const FLOW_URL = "__URL_FLOW__";
export const APP_KEY = "__APP_KEY__";

// Se usa solo para armar el link "abrir en SharePoint" del buscador. Ese link
// pide sesion de Microsoft 365; el boton Descargar funciona sin sesion.
export const SITIO_SHAREPOINT =
  "https://tackersrl505.sharepoint.com/sites/QHSE";

export const CARPETA_RAIZ = "16 - Mediciones Higiénicas LUZ y RUIDO";
