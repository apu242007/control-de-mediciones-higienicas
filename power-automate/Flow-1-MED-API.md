# Flow 1 — `MED-API`

Único endpoint HTTP que usa la aplicación web. Tres acciones en un solo flow
(`subir`, `listar`, `descargar`), porque así hay **una sola URL** que proteger y
**un solo secret** que rotar.

> Power Automate no guarda los flows en formato de texto, así que este documento
> **es** la fuente de verdad del diseño. Después de cualquier cambio en el flow:
> exportar el paquete (`… → Exportar → Paquete .zip`), guardarlo en esta carpeta
> y actualizar este archivo.

---

## Datos a sustituir

| Marcador | Valor |
|---|---|
| `<SITIO>` | `https://tackersrl505.sharepoint.com/sites/QHSE` |
| `<BIBLIOTECA>` | `Documentos QHSE` |
| `<RAIZ>` | `16 - Mediciones Higiénicas LUZ y RUIDO` |
| `<RAIZ_SERVIDOR>` | `/sites/QHSE/Documentos QHSE/16 - Mediciones Higiénicas LUZ y RUIDO` |
| `<LISTA_CONFIG>` | `MedicionesConfig` |
| `<APP_KEY>` | valor que también va al secret `APP_KEY` de GitHub |

---

## Árbol final

```
Cuando se recibe una solicitud HTTP
├─ Verificar_clave            ← Condición: 401 y Terminar si no coincide
├─ Init_varAccion             ← String
├─ Init_varClavePin           ← String
├─ Init_varPinOk              ← Boolean
├─ Init_varFallidos           ← Integer
├─ Obtener_config             ← SP Obtener elementos (MedicionesConfig)
├─ Verificar_bloqueo          ← Condición: 429 y Terminar si está bloqueado
├─ Verificar_pin              ← Condición
│   ├─ Si NO: Sumar_fallido → Respuesta_401 → Terminar
│   └─ Si SÍ: Resetear_fallidos
└─ Conmutador_accion
    ├─ subir     → Crear_carpeta → Crear_archivo → Actualizar_propiedades → Respuesta_subir
    ├─ listar    → Consultar_archivos → Seleccionar_filas → Respuesta_listar
    ├─ descargar → Obtener_contenido → Respuesta_descargar
    └─ default   → Respuesta_accion_invalida (400)
```

**Toda rama termina en una acción `Respuesta`, el `default` incluido.** Un camino
sin `Respuesta` devuelve *202 Accepted sin cuerpo*, y el cliente lo lee como un
éxito con datos vacíos: la pantalla muestra «no hay nada» en lugar de un error.
Es el modo de falla más caro de diagnosticar, justamente porque no parece una falla.

---

## 1 · Disparador — «Cuando se recibe una solicitud HTTP»

| Campo | Valor |
|---|---|
| ¿Quién puede desencadenar el flujo? | **Cualquier persona** |
| Método *(Mostrar opciones avanzadas)* | `POST` |
| Esquema JSON del cuerpo de la solicitud | **DEJAR VACÍO** |

> El esquema vacío no es un descuido. Con un esquema cargado, Power Automate
> valida cada `triggerBody()?['campo']` contra él y rechaza en tiempo de diseño
> cualquier campo que la app agregue después, con el error *«'x' ya no está
> presente en el esquema de la operación»*. La app es la fuente de verdad del
> payload.

Guardá el flow y recién entonces aparece la URL, en la cabecera del disparador.

---

## 2 · `Verificar_clave` — Condición

Freno para bots. **No es autenticación**: la clave viaja en el JavaScript que
descarga el navegador y cualquiera puede leerla. El control real es el PIN.

- Izquierda (`fx`): `triggerOutputs()?['headers']?['x-app-key']`
- Operador: **es igual a**
- Derecha: `<APP_KEY>`

**Rama «Si no»:**

1. `Respuesta` → Código de estado `401`, Cuerpo:
   ```json
   { "error": "Solicitud no autorizada." }
   ```
2. `Terminar` → Estado `Failed`

**Rama «Si sí»:** vacía. El flow sigue por abajo.

---

## 3 · Variables (las cuatro en la raíz)

> `Inicializar variable` **solo funciona en la raíz del flow**. No se puede
> dentro de un `Conmutador`, una `Condición` ni un `Aplicar a cada uno`. Por eso
> están todas acá arriba y más abajo solo se usa `Establecer la variable`.

| Acción | Nombre | Tipo | Valor (`fx`) |
|---|---|---|---|
| `Init_varAccion` | `varAccion` | String | `toLower(coalesce(triggerBody()?['accion'], ''))` |
| `Init_varClavePin` | `varClavePin` | String | `if(equals(variables('varAccion'), 'subir'), 'PIN_CARGA', 'PIN_CONSULTA')` |
| `Init_varPinOk` | `varPinOk` | Boolean | `false` |
| `Init_varFallidos` | `varFallidos` | Integer | `0` |

Subir documentos y consultarlos usan PIN distintos: así se puede dar acceso de
lectura a alguien sin habilitarlo a cargar.

---

## 4 · `Obtener_config` — SharePoint · «Obtener elementos»

| Campo | Valor |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Nombre de la lista | `<LISTA_CONFIG>` |
| Consulta de filtro *(avanzadas)* (`fx`) | `concat('Title eq ''', variables('varClavePin'), '''')` |
| Cantidad máxima de elementos | `1` |

---

## 5 · `Verificar_bloqueo` — Condición

Un PIN de cuatro dígitos son 10.000 combinaciones: sin bloqueo se agota por
fuerza bruta en minutos. **El contador es el control, no el PIN.**

- Izquierda (`fx`):
  ```
  ticks(coalesce(first(body('Obtener_config')?['value'])?['CfgBloqueadoHasta'], '2000-01-01T00:00:00Z'))
  ```
- Operador: **es mayor que**
- Derecha (`fx`): `ticks(utcNow())`

**Rama «Si sí»** (está bloqueado):

1. `Respuesta` → `429`, Cuerpo:
   ```json
   { "error": "Demasiados intentos fallidos. Volvé a probar en unos minutos." }
   ```
2. `Terminar` → `Failed`

**Rama «Si no»:** vacía.

---

## 6 · `Verificar_pin` — Condición

- Izquierda (`fx`): `first(body('Obtener_config')?['value'])?['CfgValor']`
- Operador: **es igual a**
- Derecha (`fx`): `coalesce(triggerBody()?['pin'], '')`

### Rama «Si no» — PIN incorrecto

**6a · `Sumar_fallido`** — SharePoint · «Actualizar elemento»

| Campo | Valor |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Nombre de la lista | `<LISTA_CONFIG>` |
| Id (`fx`) | `first(body('Obtener_config')?['value'])?['ID']` |
| Título (`fx`) | `variables('varClavePin')` |
| Valor (`fx`) | `first(body('Obtener_config')?['value'])?['CfgValor']` |
| Intentos fallidos (`fx`) | `add(int(coalesce(first(body('Obtener_config')?['value'])?['CfgFallidos'], 0)), 1)` |
| Bloqueado hasta (`fx`) | ver abajo |

```
if(
  greaterOrEquals(add(int(coalesce(first(body('Obtener_config')?['value'])?['CfgFallidos'], 0)), 1), 5),
  addMinutes(utcNow(), 15),
  null
)
```

Al quinto fallo consecutivo, quince minutos de bloqueo.

> `Actualizar elemento` exige **todas** las columnas obligatorias de la lista,
> `Título` incluida, aunque el cambio no las toque. Si mandás `Título` vacío la
> borrás; por eso se reenvía el valor actual. El importador reporta **una
> columna faltante por intento**, así que conviene mandarlas todas de una.

**6b · `Respuesta_401`** → `401`:
```json
{ "error": "PIN incorrecto." }
```

**6c · `Terminar`** → `Failed`

### Rama «Si sí» — PIN correcto

**`Resetear_fallidos`** — «Actualizar elemento», igual que 6a pero con
`Intentos fallidos` = `0` y `Bloqueado hasta` = `null`.

Configurá **`… → Configurar ejecución después`** de esta acción para que también
corra si viene de un estado normal; si preferís, se puede omitir cuando
`CfgFallidos` ya es 0, pero dejarla siempre es más simple y cuesta lo mismo.

---

## 7 · `Conmutador_accion`

- Activar (`fx`): `variables('varAccion')`

### Caso `subir`

**7a · `Crear_carpeta`** — SharePoint · «Crear nueva carpeta»

| Campo | Valor |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Nombre de la biblioteca | `<BIBLIOTECA>` |
| Ruta de acceso de la carpeta (`fx`) | ver abajo |

```
concat('<RAIZ>/', triggerBody()?['carpetaTipo'], '/', triggerBody()?['carpetaEquipo'], '/', triggerBody()?['carpetaAnio'])
```

**Esta acción falla si la carpeta ya existe, y eso es normal.** Configurá
`… → Configurar ejecución después` de la acción **siguiente** para que corra
también con `Se produjo un error` y `Se ha omitido`, no solo con
`Es correcto`. De lo contrario la segunda carga a la misma carpeta corta el flow.

**7b · `Crear_archivo`** — SharePoint · «Crear archivo»

| Campo | Valor |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Ruta de acceso de la carpeta (`fx`) | `concat('/<BIBLIOTECA>/<RAIZ>/', triggerBody()?['carpetaTipo'], '/', triggerBody()?['carpetaEquipo'], '/', triggerBody()?['carpetaAnio'])` |
| Nombre de archivo (`fx`) | `triggerBody()?['nombreArchivo']` |
| Contenido del archivo (`fx`) | `base64ToBinary(triggerBody()?['contenidoBase64'])` |

⚠️ **Tres trampas en «Contenido del archivo», las tres producen un PDF roto:**

1. El campo tiene que contener **solo** la expresión. Si la interfaz te arma un
   objeto `{ "contentBytes": …, "name": … }`, el archivo en SharePoint va a
   contener ese JSON como texto en lugar de los bytes. Revisá con
   **`… → Ver código`**: el `body` debe ser una cadena simple, no un objeto. Si
   la interfaz insiste en envolverlo, borrá la acción y agregala de nuevo
   cargando los campos desde la pestaña `fx`, nunca desde el selector de archivo.

2. La expresión tiene que terminar **exactamente** en el paréntesis de cierre. Un
   `\r\n` o un espacio detrás convierte el valor en una plantilla de texto y los
   bytes se corrompen. En el diseñador el campo se ve idéntico con o sin el
   espacio: **solo se detecta en Ver código.**

3. Es `base64ToBinary`, no `dataUriToBinary`. La app manda el base64 pelado, sin
   el prefijo `data:application/pdf;base64,`.

**7c · `Actualizar_propiedades`** — SharePoint · «Actualizar propiedades del archivo»

| Campo | Valor (`fx`) |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Nombre de la biblioteca | `<BIBLIOTECA>` |
| Id | `outputs('Crear_archivo')?['body/ItemId']` |
| Equipo · Valor | `triggerBody()?['equipo']` |
| Cliente | `triggerBody()?['cliente']` |
| Tipo de medición · Valor | `triggerBody()?['tipoMedicion']` |
| Fecha de medición | `triggerBody()?['fechaMedicion']` |
| Fecha de vencimiento | `triggerBody()?['fechaVencimiento']` |
| Vigencia (meses) | `if(equals(triggerBody()?['vigenciaMeses'], null), null, int(triggerBody()?['vigenciaMeses']))` |

> Para las columnas **Número** usá siempre `if(equals(…, null), null, int(…))`.
> Sin la guarda, una cadena vacía se convierte en `0` y la columna queda con un
> dato falso en lugar de vacía.
>
> Para **Elección** con valor opcional va `if(empty(…), null, …)`, no
> `coalesce(…)`: `coalesce` devuelve una cadena vacía, que el conector rechaza.
> Acá `equipo` y `tipoMedicion` siempre vienen cargados desde la app, así que la
> expresión directa alcanza.

**7d · `Respuesta_subir`** → `200`

Cabecera: `Content-Type: application/json`

```json
{
  "ok": true,
  "nombreArchivo": "@{outputs('Crear_archivo')?['body/Name']}",
  "rutaRelativa": "@{outputs('Crear_archivo')?['body/Path']}",
  "urlSharePoint": "@{outputs('Crear_archivo')?['body/{Link}']}"
}
```

---

### Caso `listar`

**7e · `Consultar_archivos`** — SharePoint · «Enviar una solicitud HTTP a SharePoint»

El conector nativo «Obtener archivos (solo propiedades)» no permite limitar la
consulta a una subcarpeta, y la biblioteca `Documentos QHSE` tiene mucho más que
mediciones. Con REST se filtra por ruta en una sola llamada.

> ### ⚠️ No usar `/items`: en esta biblioteca devuelve vacío
>
> El endpoint `_api/web/GetList(...)/items` responde `200` con **cero filas**, con
> filtro o sin él, aunque la biblioteca tenga más de mil elementos (quirk de
> SharePoint). La consecuencia es la peor: el flow termina «Succeeded», el
> buscador dice «No hay documentos» y no hay ningún error que perseguir.
> La consulta se hace por **`RenderListDataAsStream`** con CAML, que es lo que usa
> la propia interfaz de SharePoint.

La definición exacta la genera [`Deploy-Flows.ps1`](Deploy-Flows.ps1); esa es la
fuente de verdad. Lo que arma:

| Campo | Valor |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Método | `POST` |
| Uri | `_api/web/lists(guid'<ID_BIBLIOTECA>')/RenderListDataAsStream` |
| Cuerpo (`fx`) | JSON con `RenderOptions: 2` y un `ViewXml` CAML, ver abajo |

Cabeceras: `Accept` y `Content-Type`, ambos `application/json;odata=nometadata`.

El CAML es un `Scope='RecursiveAll'` con seis condiciones anidadas en `And`, en
este orden: prefijo de ruta, `FSObjType = 0` (solo archivos, sin carpetas) y los
cinco filtros opcionales (`MedTipo`, `MedEquipo`, `MedCliente`, `MedFechaMedicion`
≥ desde y ≤ hasta). Un filtro que no vino se reemplaza por una condición siempre
verdadera (`ID <> 0`), para que el árbol tenga siempre la misma forma. Los valores
del usuario se escapan (`& < > '`) y se les quitan `"` y `\` antes de entrar al
CAML, que viaja dentro de un JSON armado a mano. El prefijo de ruta se corta antes
del acento (`…/16 - Mediciones Hig`) a propósito, para no depender de la
codificación del carácter.

`ViewFields`: `ID, FileLeafRef, FileRef, MedEquipo, MedCliente, MedTipo,
MedFechaMedicion, MedFechaVencimiento, MedVigenciaMeses`, con `RowLimit` 2000. La
respuesta trae las filas en `Row` (no en `value`).

**7f · `Seleccionar_filas`** — Operaciones de datos · «Seleccionar»

- Desde (`fx`): `coalesce(body('Consultar_archivos')?['Row'], json('[]'))`

Asignaciones — **cada valor va en la pestaña `fx`**:

| Clave | Valor |
|---|---|
| `id` | `int(item()?['ID'])` |
| `nombre` | `item()?['FileLeafRef']` |
| `rutaRelativa` | `item()?['FileRef']` |
| `equipo` | `string(coalesce(item()?['MedEquipo'], ''))` |
| `cliente` | `string(coalesce(item()?['MedCliente'], ''))` |
| `tipoMedicion` | `string(coalesce(item()?['MedTipo'], ''))` |
| `fechaMedicion` | fecha a ISO, ver abajo |
| `fechaVencimiento` | fecha a ISO, ver abajo |
| `urlSharePoint` | `concat('https://tackersrl505.sharepoint.com', item()?['FileRef'])` |

**Fechas.** `RenderListDataAsStream` devuelve las fechas ya formateadas para la
configuración regional del sitio (`13/06/2026`), no en ISO, y el cliente ordena y
clasifica por cadena ISO. Se convierten a `2026-06-13T12:00:00Z`, el mismo formato
que devolvía `/items`:

```
if(equals(length(string(coalesce(item()?['MedFechaMedicion'], ''))), 10),
   concat(substring(<s>, 6, 4), '-', substring(<s>, 3, 2), '-', substring(<s>, 0, 2), 'T12:00:00Z'),
   '')
```

donde `<s>` es `string(coalesce(item()?['MedFechaMedicion'], ''))`. Si alguien
cambia el formato de fecha regional del sitio, la conversión devuelve vacío y el
buscador muestra todo «sin fecha»: es el primer lugar donde mirar.

> Con `RenderListDataAsStream` las columnas Elección llegan como **texto plano**,
> así que ya no hace falta la guarda `startsWith(string(X), '{')` que exigía la
> consulta anterior. Sigue valiendo la regla general: nunca `item()?['X']?['Value']`
> sobre algo que puede ser una cadena, porque una sola fila tumba el `Seleccionar`
> completo y el navegador ve **502 NoResponse**, que además **anda con cero
> resultados y falla en cuanto aparece uno**. Probá siempre con datos.

**7g · `Respuesta_listar`** → `200`

Cabecera: `Content-Type: application/json`

```json
{
  "ok": true,
  "items": @{body('Seleccionar_filas')},
  "truncado": @{greaterOrEquals(length(body('Seleccionar_filas')), 2000)}
}
```

---

### Caso `descargar`

**7h · `Obtener_contenido`** — SharePoint · «Obtener el contenido del archivo mediante la ruta de acceso»

| Campo | Valor |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Ruta de acceso del archivo (`fx`) | `replace(triggerBody()?['rutaRelativa'], '/sites/QHSE', '')` |
| Inferir tipo de contenido | `No` |

> La ruta que manda la app es la que salió de `FileRef` en el listado. SharePoint
> la devuelve relativa al servidor (`/sites/QHSE/...`), pero esta acción espera
> una ruta relativa al sitio; por eso se elimina el prefijo `/sites/QHSE`. La app
> **no** construye rutas por su cuenta: eso evita que alguien pida un archivo de
> otra carpeta de la biblioteca manipulando el pedido.

**7i · `Respuesta_descargar`** → `200`

Cabecera: `Content-Type: application/json`

```json
{
  "ok": true,
  "contenidoBase64": "@{base64(body('Obtener_contenido'))}"
}
```

---

### Caso `default`

**`Respuesta_accion_invalida`** → `400`

```json
{ "error": "Acción no reconocida." }
```

---

## Lista de verificación antes de guardar

- [ ] Esquema del disparador **vacío**, no sincronizado
- [ ] Método del disparador en `POST`, «Cualquier persona» puede desencadenarlo
- [ ] Las cuatro `Inicializar variable` están en la **raíz**
- [ ] Cada campo se cargó desde la pestaña **`fx`** — ningún chip naranja del
      panel de contenido dinámico (los chips guardan referencias al esquema y se
      rompen cuando el disparador cambia)
- [ ] `Verificar_clave`, `Verificar_bloqueo` y `Verificar_pin` terminan sus ramas
      de rechazo en `Respuesta` **y** `Terminar`
- [ ] **Las cuatro** ramas del conmutador terminan en `Respuesta`, el `default`
      incluido
- [ ] `Crear_archivo` → Ver código: el `body` es una cadena que termina justo en
      `)`, sin objeto envolvente y sin espacios ni `\r\n` detrás
- [ ] `Crear_archivo` corre también si `Crear_carpeta` falla (carpeta ya existente)
- [ ] `Actualizar_propiedades` manda `Vigencia (meses)` con la guarda de `null`
- [ ] `Consultar_archivos` usa `RenderListDataAsStream` (**no** `/items`) y
      `Seleccionar_filas` lee `Row`
- [ ] `fechaMedicion` y `fechaVencimiento` se convierten a ISO
- [ ] Ningún nombre de acción repetido **en todo el flow** (no alcanza que sean
      únicos dentro de su rama: `body('X')` resolvería a cualquiera de las dos)
- [ ] URL del disparador copiada al secret `URL_FLOW` de GitHub
- [ ] Flow exportado como `.zip` y guardado en esta carpeta

---

## Pruebas obligatorias

Probá **las dos puntas**. Un reporte probado solo contra un conjunto vacío no
está probado: `if()` cortocircuita, así que un error de sintaxis en la rama con
datos no aparece hasta que hay datos.

| Caso | Se espera |
|---|---|
| `listar` sin ningún documento cargado | `200` con `items: []` |
| `listar` con al menos un documento | `200` con las filas — **acá aparece el error de selección de propiedad si falta la guarda de tipo** |
| `subir` un PDF chico | `200`, archivo en su carpeta, columnas cargadas |
| `subir` a una carpeta que ya existe | `200` — verifica el `Configurar ejecución después` |
| `subir` un PDF de ~8 MB | `200` — verifica que no se agote el tiempo |
| `descargar` un archivo listado | `200` con `contenidoBase64` y el PDF abre bien |
| PIN incorrecto | `401`, y `CfgFallidos` subió en uno |
| PIN incorrecto cinco veces | `429`, y `CfgBloqueadoHasta` quedó a quince minutos |
| PIN correcto después de dos fallos | `200`, y `CfgFallidos` volvió a `0` |
| `accion` inexistente | `400` |
| Sin la cabecera `x-app-key` | `401` |

## Ante cualquier falla, leer el historial primero

`make.powerautomate.com` → el flow → **Historial de ejecuciones** → la corrida en
rojo → la acción que falló → **Entradas / Salidas**. Ahí está el nombre exacto de
la acción y el mensaje del motor.

Leerlo cuesta una consulta. Adivinar cuesta una vuelta entera de corregir,
importar y volver a probar.

| Síntoma | Casi siempre es |
|---|---|
| `502 NoResponse` | una acción falló y el flow terminó sin `Respuesta` |
| `202` sin cuerpo | hay un camino sin acción `Respuesta` |
| Funciona con 0 filas, falla con 1 | falta la guarda de tipo en el `Seleccionar` |
| El PDF en SharePoint no abre | `Crear_archivo`, las tres trampas del punto 7b |
| `Missing Authorization header for a privileged call` | expiró la conexión de SharePoint. Se arregla en **Conexiones → Reparar**, no con código |
| Se importó «correctamente» y nada cambió | hay dos flows con el mismo nombre y la importación fue al otro |
