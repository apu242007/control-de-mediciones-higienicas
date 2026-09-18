# Flow 2 — `MED-Alertas`

Corre solo, una vez por día, y manda **un correo por cada equipo y tipo de
medición cuya medición más reciente está por vencer o ya venció**.

> La definición exacta la genera [`Deploy-Flows.ps1`](Deploy-Flows.ps1): esa es la
> fuente de verdad, y el HTML del correo vive en su variable `$mailBody`. Esta guía
> explica la lógica y sirve para armarlo o revisarlo a mano.

> ### Por qué no se usan las alertas nativas de SharePoint
>
> Las «Alertas» que ofrece SharePoint avisan cuando **alguien modifica** un
> archivo. No pueden avisar «esto vence en quince días», porque no evalúan
> fechas futuras: no existe la opción, en ninguna versión.
>
> La única forma de avisar por vencimiento es un flujo programado que corra
> periódicamente y compare la columna de vencimiento contra la fecha de hoy. Eso
> es este flow.

---

## Datos a sustituir

| Marcador | Valor |
|---|---|
| `<SITIO>` | `https://tackersrl505.sharepoint.com/sites/QHSE` |
| `<BIBLIOTECA>` | `Documentos QHSE` |
| `<ID_BIBLIOTECA>` | `3bcd9efb-57ca-4acf-b841-2e2557cc09d5` |
| `<RAIZ_SERVIDOR>` | `/sites/QHSE/Documentos QHSE/16 - Mediciones Higiénicas LUZ y RUIDO` |
| `<DESTINATARIO>` | `jcastro@tackertools.com` |

---

## Comportamiento

**Solo avisa por el último documento de cada par Equipo + Tipo.** Cuando se carga
una medición nueva de Tacker 01 / Iluminación, la anterior queda reemplazada y
deja de generar avisos aunque su fecha ya haya pasado. «Último» = la fecha de
medición más reciente; si dos empatan, el de Id mayor.

Sobre ese documento, los hitos de aviso son **30, 15 y 7 días antes** del
vencimiento. Después del vencimiento vuelve a avisar **una vez por semana**
mientras siga sin renovarse.

Cada documento recibe **un correo por hito**, no uno por día. El control es la
columna `MedAlertaEnviada`: el flow anota ahí qué hito ya notificó y no lo repite.
Sin esa columna, un documento a 25 días del vencimiento generaría un correo
diario durante casi un mes.

---

## Árbol final

```
Periodicidad (diaria, 08:00 ART)
├─ Init_varHoy                ← String
├─ Init_varVistos             ← String, vacío (las variables van en la raíz)
├─ Consultar_vencimientos     ← Enviar solicitud HTTP a SharePoint (RenderListDataAsStream)
├─ Normalizar_filas           ← Seleccionar
└─ Recorrer_documentos        ← Aplicar a cada uno (concurrencia 1)
    └─ Verificar_ultimo       ← Condición: ¿es el primero de su Equipo+Tipo?
        └─ (sí)
            ├─ Registrar_visto        ← Anexar a variable de cadena
            └─ Evaluar_alerta         ← Condición: ¿vence en ≤ 30 días y hito nuevo?
                └─ (sí)
                    ├─ Calcular_hito          ← Redactar
                    ├─ Enviar_correo          ← Outlook · Enviar un correo electrónico (V2)
                    └─ Marcar_notificado      ← SharePoint · Actualizar propiedades del archivo
```

---

## 1 · Disparador — «Periodicidad»

| Campo | Valor |
|---|---|
| Intervalo | `1` |
| Frecuencia | `Día` |
| Zona horaria *(avanzadas)* | `(UTC-03:00) Ciudad de Buenos Aires` |
| A estas horas | `8` |
| En estos minutos | `0` |

---

## 2 · Variables

`Init_varHoy` — `varHoy`, `String`, valor (`fx`):
`formatDateTime(convertTimeZone(utcNow(), 'UTC', 'Argentina Standard Time'), 'yyyy-MM-dd')`.
Se usa la fecha **argentina**, no la UTC, para que el cálculo no se corra un día si
alguien mueve el horario del disparador a la noche.

`Init_varVistos` — `varVistos`, `String`, valor vacío. Va acumulando las claves
`|Equipo~Tipo|` de los grupos que ya se procesaron.

---

## 3 · `Consultar_vencimientos` — «Enviar una solicitud HTTP a SharePoint»

> ### ⚠️ No usar `/items`: en esta biblioteca devuelve vacío
>
> La primera versión de este flow consultaba `_api/web/GetList(...)/items` con
> filtro. Ese endpoint responde `200` con **cero filas**, aunque haya mil
> documentos. El flow terminaba «Succeeded» todos los días y **no avisó nunca de
> nada**: no hay error que perseguir, solo un silencio. Se consulta por
> `RenderListDataAsStream`, igual que la interfaz de SharePoint.

| Campo | Valor |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Método | `POST` |
| Uri | `_api/web/lists(guid'<ID_BIBLIOTECA>')/RenderListDataAsStream` |
| Cabeceras | `Accept` y `Content-Type`: `application/json;odata=nometadata` |
| Cuerpo | JSON con `RenderOptions: 2` y el `ViewXml` de abajo |

CAML: `Scope='RecursiveAll'`, condición `prefijo de ruta` **y** `MedFechaVencimiento`
no nula, y orden **del más nuevo al más viejo**: `MedFechaMedicion` descendente,
`ID` descendente para desempatar.

Trae **todos** los documentos con vencimiento, no solo los próximos: para saber si
un documento es el último de su grupo hay que ver también los más nuevos, aunque
vencen dentro de un año. `RowLimit` 2000.

---

## 4 · `Normalizar_filas` — Operaciones de datos · «Seleccionar»

Desde (`fx`): `coalesce(body('Consultar_vencimientos')?['Row'], json('[]'))`

Devuelve las filas con los mismos nombres de propiedad que usa el resto del flow
(`Id, FileLeafRef, FileRef, MedEquipo, MedCliente, MedTipo, MedFechaMedicion,
MedFechaVencimiento, MedVigenciaMeses, MedAlertaEnviada`).

Las dos fechas se convierten a ISO: `RenderListDataAsStream` las devuelve en el
formato regional del sitio (`31/01/2026`) y `ticks()` / `formatDateTime()` no las
leen así. La conversión es
`concat(substring(s, 6, 4), '-', substring(s, 3, 2), '-', substring(s, 0, 2), 'T12:00:00Z')`,
con `s = string(coalesce(item()?['MedFechaVencimiento'], ''))`.

---

## 5 · `Recorrer_documentos` — «Aplicar a cada uno»

- Seleccionar una salida (`fx`): `body('Normalizar_filas')`
- **Configuración ⚙️ → Control de simultaneidad: Activado, Grado de paralelismo `1`**

El paralelismo en 1 es **obligatorio**, no una cortesía: el bucle escribe la
variable `varVistos`, y las variables solo se pueden modificar dentro de un bucle
si este corre de a una iteración. Además ordena los correos y evita una ráfaga
contra el límite del conector de Outlook.

### 5·1 · `Verificar_ultimo` — Condición

```
@not(contains(variables('varVistos'), concat('|', item()?['MedEquipo'], '~', item()?['MedTipo'], '|')))
```

Como las filas llegan ordenadas del más nuevo al más viejo, la **primera vez** que
aparece un par Equipo+Tipo es su documento más reciente. Las apariciones
siguientes son documentos reemplazados y no hacen nada.

En la rama *sí*: `Registrar_visto` (Anexar a variable de cadena, `varVistos`, con
esa misma clave `concat('|', …, '|')`) y después `Evaluar_alerta`.

### 5·2 · `Evaluar_alerta` — Condición

```
@and(
  if(empty(item()?['MedFechaVencimiento']), false,
     lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 30)))),
  not(equals(coalesce(item()?['MedAlertaEnviada'], ''), <HITO>))
)
```

Es decir: vence en 30 días o menos (o ya venció) **y** todavía no fue notificado en
el hito que le corresponde hoy. `<HITO>` es la misma expresión de `Calcular_hito`.

Usá `coalesce(item()?['MedAlertaEnviada'], '')`, no la propiedad pelada: SharePoint
devuelve cadena vacía en las columnas de texto sin cargar.

### 5a · `Calcular_hito` — Operaciones de datos · «Redactar»

```
if(less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())),
   concat('vencido-',
          formatDateTime(convertTimeZone(utcNow(),'UTC','Argentina Standard Time'), 'yyyy'), '-',
          string(div(sub(dayOfYear(convertTimeZone(utcNow(),'UTC','Argentina Standard Time')), 1), 7))),
   if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 7))),  'd7',
   if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 15))), 'd15',
                                                                                        'd30')))
```

| Situación | Etiqueta |
|---|---|
| Vence en 16 a 30 días | `d30` |
| Vence en 8 a 15 días | `d15` |
| Vence en 0 a 7 días | `d7` |
| Ya venció | `vencido-2026-37` (año y número de semana) |

La etiqueta de los vencidos incluye la semana, así que al cambiar de semana deja de
coincidir con lo ya notificado y vuelve a avisar: un correo por semana, no uno por
día.

> **No usar `formatDateTime(…, 'yyyy-ww')`.** `ww` no existe en Power Automate: se
> escribe literal y la etiqueta queda fija en `vencido-2026-ww`, de modo que el
> recordatorio semanal saldría **una sola vez por año**. La semana se calcula a
> mano: `div(sub(dayOfYear(hoy), 1), 7)`.

### 5b · `Enviar_correo` — Outlook · «Enviar un correo electrónico (V2)»

| Campo | Valor |
|---|---|
| Para | `<DESTINATARIO>` |
| Asunto (`fx`) | ver abajo |
| Cuerpo | HTML de `$mailBody` en `Deploy-Flows.ps1` (modo código `</>`) |

**Asunto:**

```
concat(
  if(<VENCIDA>, 'Medición VENCIDA', 'Medición por vencer'), ' · ',
  item()?['MedTipo'], ' · ', item()?['MedEquipo'],
  if(<VENCIDA>, ' · venció el ', ' · vence el '),
  formatDateTime(item()?['MedFechaVencimiento'], 'dd/MM/yyyy')
)
```

con `<VENCIDA>` = `less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow()))`. Ejemplo:
`Medición VENCIDA · Ruido · Mase 03 · venció el 31/01/2026`.

**Cuerpo.** Tabla de 640 px con estilos en línea (compatible con Outlook), de arriba
a abajo:

1. **Encabezado** azul con «Aviso de vencimiento de medición».
2. **Banner de estado**: rojo «MEDICIÓN VENCIDA — Venció el dd/MM/aaaa (hace N
   días)» o ámbar «PRÓXIMA A VENCER — Vence el dd/MM/aaaa (en N días)».
3. Una línea de contexto: es la medición más reciente de ese equipo y tipo, y hay
   que hacer una nueva.
4. **Tabla de datos**: Equipo, Tipo de medición, Cliente / Operadora, Fecha de
   medición, Fecha de vencimiento, Vigencia aplicada y Archivo. Lo que no esté
   cargado se muestra como `s/d`.
5. Botón **Abrir documento en SharePoint**.
6. Recuadro **Qué hacer**: programar la nueva medición y cargar el PDF en la
   aplicación; al cargarlo el aviso deja de enviarse.
7. **Pie** con el motivo del envío: «una vez por semana mientras siga vencida», o
   «recordatorios a 30, 15 y 7 días» si todavía no venció.

> `div(…, 864000000000)` convierte una diferencia en *ticks* a días: un tick es
> 100 nanosegundos, así que un día son 864.000.000.000 de ellos.

### 5c · `Marcar_notificado` — SharePoint · «Actualizar propiedades del archivo»

| Campo | Valor (`fx`) |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Nombre de la biblioteca | `<BIBLIOTECA>` |
| Id | `item()?['Id']` |
| Último aviso enviado | `outputs('Calcular_hito')` |

**`… → Configurar ejecución después` de esta acción: solo `Es correcto`.**

El orden importa: **primero el correo, después la marca.** Si el correo falla, la
marca no se escribe y el documento se vuelve a intentar mañana. Al revés, un
fallo de Outlook dejaría el documento marcado como notificado sin que nadie haya
recibido nada — y nadie se enteraría hasta la auditoría.

> Si la biblioteca tiene otras columnas obligatorias, `Actualizar propiedades del
> archivo` las va a exigir todas, aunque no las cambies. El importador reporta
> una por intento: conviene revisar la lista de columnas de una sola vez y
> reenviar el valor actual de cada obligatoria.

---

## Lista de verificación antes de guardar

- [ ] Zona horaria del disparador en Buenos Aires (si queda en UTC, el aviso sale
      a las 5 de la mañana)
- [ ] La consulta usa `RenderListDataAsStream`, **no** `/items`
- [ ] El CAML ordena por `MedFechaMedicion` **descendente** (si queda ascendente,
      avisaría por el documento más viejo de cada grupo)
- [ ] `Init_varVistos` está en la **raíz**, no dentro del bucle
- [ ] Simultaneidad del bucle en `1`
- [ ] Las fechas de `Normalizar_filas` se convierten a ISO
- [ ] El hito de los vencidos usa `dayOfYear`, no `'yyyy-ww'`
- [ ] `Enviar_correo` está **antes** de `Marcar_notificado`
- [ ] `Marcar_notificado` corre solo si el correo salió bien

---

## Pruebas

No se puede esperar treinta días para ver si funciona. Se fuerza. El flow se
dispara a mano con la API de administración (`POST …/flows/<id>/triggers/Periodicidad/run`),
y el historial de cada iteración se lee en `…/runs/<corrida>/actions/<acción>/repetitions`.

1. **Sin datos.** Con la biblioteca sin ningún vencimiento, la corrida termina
   `Succeeded` y el bucle no entra: valida la estructura y la consulta.
2. **Con datos.** Con los vencimientos cargados, verificá cuántas iteraciones
   evalúan el aviso. Con 44 documentos en 20 pares Equipo+Tipo se esperan:
   `Verificar_ultimo` 44 iteraciones, `Evaluar_alerta` **20** ejecutadas y 24
   omitidas (los reemplazados).
3. **Solo el último avisa.** Los correos salen únicamente para los documentos que
   son el último de su par **y** están vencidos o por vencer.
4. **No repite.** Volvé a ejecutarlo sin tocar nada: `Enviar_correo` tiene que
   quedar en `Skipped` en todas las iteraciones. Así se comprueba que la marca
   evita el envío diario.
5. **Para volver a ver un correo**, vaciá **Último aviso enviado** de ese
   documento y ejecutá de nuevo.

> **Probalo también con la biblioteca sin ningún vencimiento próximo.** Con cero
> filas el bucle no entra nunca, así que un error de sintaxis dentro del correo
> no aparece: `if()` cortocircuita y la rama que no se evalúa no se valida.
> Al revés también: un mes sin datos esconde errores que solo salen con datos.
> Hay que correr las dos puntas.

---

## Vigilancia

Power Automate le manda un correo al **dueño del flow** cuando una ejecución
falla, y después de varias fallas seguidas puede desactivarlo solo. No silencies
esos avisos: son la única señal de que el control de vencimientos dejó de correr.

Ojo con el caso contrario, que es el que ya pasó una vez: un flow que termina
`Succeeded` todos los días **no prueba que esté avisando**. La única prueba es un
documento vencido que genere un correo.
