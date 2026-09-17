# Flow 2 — `MED-Alertas`

Corre solo, una vez por día, y manda **un correo por cada medición que está por
vencer o ya venció**.

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
| `<RAIZ_SERVIDOR>` | `/sites/QHSE/Documentos QHSE/16 - Mediciones Higiénicas LUZ y RUIDO` |
| `<DESTINATARIO>` | `jcastro@tackertools.com` |

---

## Comportamiento

Hitos de aviso: **30, 15 y 7 días antes**, y **el día del vencimiento**. Después
del vencimiento vuelve a avisar **una vez por semana** mientras siga sin
renovarse, para que no se pierda de vista.

Cada documento recibe **un correo por hito**, no uno por día. El control es la
columna `MedAlertaEnviada`: el flow anota ahí qué hito ya notificó y no lo repite.
Sin esa columna, un documento a 25 días del vencimiento generaría un correo
diario durante casi un mes.

---

## Árbol final

```
Periodicidad (diaria, 08:00 ART)
├─ Init_varHoy                ← String
├─ Consultar_vencimientos     ← Enviar solicitud HTTP a SharePoint
├─ Filtrar_a_notificar        ← Filtrar matriz
└─ Recorrer_documentos        ← Aplicar a cada uno (concurrencia 1)
    ├─ Init… (NO: las variables van arriba)
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

## 2 · `Init_varHoy` — Inicializar variable

| Campo | Valor |
|---|---|
| Nombre | `varHoy` |
| Tipo | `String` |
| Valor (`fx`) | `formatDateTime(convertTimeZone(utcNow(), 'UTC', 'Argentina Standard Time'), 'yyyy-MM-dd')` |

Se usa la fecha **argentina**, no la UTC. A las 08:00 de Argentina son las 11:00
UTC del mismo día, así que acá coinciden; pero dejarlo explícito evita que el
cálculo se corra un día si alguien mueve el horario del disparador a la noche.

---

## 3 · `Consultar_vencimientos` — «Enviar una solicitud HTTP a SharePoint»

| Campo | Valor |
|---|---|
| Dirección del sitio | `<SITIO>` |
| Método | `GET` |
| Uri (`fx`) | ver abajo |

```
concat(
  '_api/web/GetList(''/sites/QHSE/Documentos QHSE'')/items',
  '?$select=Id,FileLeafRef,FileRef,MedEquipo,MedCliente,MedTipo,MedFechaMedicion,MedFechaVencimiento,MedAlertaEnviada',
  '&$filter=startswith(FileRef,''<RAIZ_SERVIDOR>'')',
  ' and MedFechaVencimiento ne null',
  ' and MedFechaVencimiento le datetime''', formatDateTime(addDays(utcNow(), 30), 'yyyy-MM-dd'), 'T23:59:59Z''',
  '&$top=2000'
)
```

Cabeceras:

| Clave | Valor |
|---|---|
| `Accept` | `application/json;odata=nometadata` |

El filtro ya descarta todo lo que vence dentro de más de treinta días, así que el
flow procesa pocas filas por día.

> `MedFechaVencimiento` tiene que estar **indexada** en la biblioteca — el script
> `sharepoint/Setup-Columnas-Mediciones.ps1` la crea así. Sin índice, cuando la
> biblioteca pase los 5000 elementos este filtro empieza a fallar con un error de
> umbral de vista, y el aviso se corta sin que nadie lo note.

---

## 4 · `Filtrar_a_notificar` — Operaciones de datos · «Filtrar matriz»

- Desde (`fx`): `body('Consultar_vencimientos')?['value']`

Condición — en modo **avanzado**, pegando la expresión completa:

```
@not(equals(
  coalesce(item()?['MedAlertaEnviada'], ''),
  if(less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())),
     concat('vencido-', formatDateTime(convertTimeZone(utcNow(),'UTC','Argentina Standard Time'), 'yyyy-ww')),
     if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 7))),  'd7',
     if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 15))), 'd15',
                                                                                          'd30')))
))
```

Es decir: pasa solo lo que **todavía no fue notificado en el hito que le
corresponde hoy**.

Los hitos:

| Situación | Etiqueta |
|---|---|
| Vence en 16 a 30 días | `d30` |
| Vence en 8 a 15 días | `d15` |
| Vence en 0 a 7 días | `d7` |
| Ya venció | `vencido-2026-38` (año y número de semana) |

La etiqueta de los vencidos incluye la semana, así que al cambiar de semana deja
de coincidir con lo ya notificado y vuelve a avisar. Un documento vencido y sin
renovar genera un correo por semana, no uno por día.

> Usá `coalesce(item()?['MedAlertaEnviada'], '')`, no la propiedad pelada:
> SharePoint devuelve cadena vacía en las columnas de texto sin cargar, y los
> documentos recién subidos la tienen vacía.

---

## 5 · `Recorrer_documentos` — «Aplicar a cada uno»

- Seleccionar una salida (`fx`): `body('Filtrar_a_notificar')`
- **Configuración ⚙️ → Control de simultaneidad: Activado, Grado de paralelismo `1`**

> El paralelismo en 1 no es por conflicto de escritura — cada iteración toca un
> archivo distinto —, es para que los correos lleguen en orden y no se dispare
> una ráfaga contra el límite del conector de Outlook.

> ⚠️ Fijate que **la entrada sea la matriz**, `body('Filtrar_a_notificar')`, y no
> el cuerpo completo del paso anterior. Si dejás el chip que el diseñador engancha
> solo, el bucle itera sobre las claves de nivel superior en vez de sobre las
> filas, y cada iteración falla porque `item()?['FileLeafRef']` no existe.

### 5a · `Calcular_hito` — Operaciones de datos · «Redactar»

Entradas (`fx`) — misma expresión que usa el filtro, para que la etiqueta que se
guarda sea exactamente la que se evaluó:

```
if(less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())),
   concat('vencido-', formatDateTime(convertTimeZone(utcNow(),'UTC','Argentina Standard Time'), 'yyyy-ww')),
   if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 7))),  'd7',
   if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 15))), 'd15',
                                                                                        'd30')))
```

### 5b · `Enviar_correo` — Outlook · «Enviar un correo electrónico (V2)»

| Campo | Valor |
|---|---|
| Para | `<DESTINATARIO>` |
| Asunto (`fx`) | ver abajo |
| Cuerpo | ver abajo (modo HTML) |

**Asunto:**

```
concat(
  if(less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())), '🔴 VENCIDA — ', '🟠 Por vencer — '),
  'Medición ',
  if(startsWith(string(item()?['MedTipo']), '{'), json(string(item()?['MedTipo']))?['Value'], string(coalesce(item()?['MedTipo'], 's/d'))),
  ' · ',
  if(startsWith(string(item()?['MedEquipo']), '{'), json(string(item()?['MedEquipo']))?['Value'], string(coalesce(item()?['MedEquipo'], 's/d'))),
  ' · vence ',
  formatDateTime(item()?['MedFechaVencimiento'], 'dd/MM/yyyy')
)
```

**Cuerpo** — poné el editor en modo código HTML (`</>`) y pegá:

```html
<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#14202b;max-width:640px">

  @{if(less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())),
    concat('<div style="background:#fdecea;border-left:6px solid #b91c1c;padding:14px 16px;border-radius:6px;margin-bottom:18px">',
           '<div style="font-weight:700;color:#b91c1c;font-size:15px">🔴 MEDICIÓN VENCIDA</div>',
           '<div style="color:#b91c1c;margin-top:4px">Venció el ',
           formatDateTime(item()?['MedFechaVencimiento'], 'dd/MM/yyyy'),
           ' — hace ', string(div(sub(ticks(utcNow()), ticks(item()?['MedFechaVencimiento'])), 864000000000)),
           ' días. Hay que renovarla.</div></div>'),
    concat('<div style="background:#fef3c7;border-left:6px solid #d97706;padding:14px 16px;border-radius:6px;margin-bottom:18px">',
           '<div style="font-weight:700;color:#b45309;font-size:15px">🟠 PRÓXIMA A VENCER</div>',
           '<div style="color:#b45309;margin-top:4px">Vence el ',
           formatDateTime(item()?['MedFechaVencimiento'], 'dd/MM/yyyy'),
           ' — en ', string(div(sub(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())), 864000000000)),
           ' días.</div></div>')
  )}

  <table cellpadding="8" cellspacing="0" style="border-collapse:collapse;width:100%">
    <tr>
      <td style="background:#e8f1f9;font-weight:600;width:170px;border:1px solid #d3dce4">Equipo</td>
      <td style="border:1px solid #d3dce4">@{if(startsWith(string(item()?['MedEquipo']), '{'), json(string(item()?['MedEquipo']))?['Value'], string(coalesce(item()?['MedEquipo'], 's/d')))}</td>
    </tr>
    <tr>
      <td style="background:#e8f1f9;font-weight:600;border:1px solid #d3dce4">Tipo de medición</td>
      <td style="border:1px solid #d3dce4">@{if(startsWith(string(item()?['MedTipo']), '{'), json(string(item()?['MedTipo']))?['Value'], string(coalesce(item()?['MedTipo'], 's/d')))}</td>
    </tr>
    <tr>
      <td style="background:#e8f1f9;font-weight:600;border:1px solid #d3dce4">Cliente</td>
      <td style="border:1px solid #d3dce4">@{string(coalesce(item()?['MedCliente'], 's/d'))}</td>
    </tr>
    <tr>
      <td style="background:#e8f1f9;font-weight:600;border:1px solid #d3dce4">Fecha de medición</td>
      <td style="border:1px solid #d3dce4">@{if(empty(coalesce(item()?['MedFechaMedicion'], '')), 's/d', formatDateTime(item()?['MedFechaMedicion'], 'dd/MM/yyyy'))}</td>
    </tr>
    <tr>
      <td style="background:#e8f1f9;font-weight:600;border:1px solid #d3dce4">Fecha de vencimiento</td>
      <td style="border:1px solid #d3dce4;font-weight:700">@{formatDateTime(item()?['MedFechaVencimiento'], 'dd/MM/yyyy')}</td>
    </tr>
    <tr>
      <td style="background:#e8f1f9;font-weight:600;border:1px solid #d3dce4">Archivo</td>
      <td style="border:1px solid #d3dce4">@{item()?['FileLeafRef']}</td>
    </tr>
  </table>

  <p style="margin-top:20px">
    <a href="@{concat('https://tackersrl505.sharepoint.com', item()?['FileRef'])}"
       style="background:#0b3d6b;color:#fff;padding:11px 20px;border-radius:7px;
              text-decoration:none;font-weight:600;display:inline-block">
      Abrir el documento
    </a>
  </p>

  <p style="color:#5b6b7a;font-size:12px;margin-top:24px;border-top:1px solid #d3dce4;padding-top:12px">
    Aviso automático del control de mediciones higiénicas.
    Este correo se manda una vez por hito (30, 15 y 7 días antes del
    vencimiento), y una vez por semana mientras la medición siga vencida.
  </p>
</div>
```

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
- [ ] `MedFechaVencimiento` está indexada en la biblioteca
- [ ] `Filtrar_a_notificar` está en modo **avanzado**, con la expresión completa
- [ ] La entrada de `Recorrer_documentos` es `body('Filtrar_a_notificar')`, no el
      cuerpo completo del paso anterior
- [ ] Simultaneidad del bucle en `1`
- [ ] `Enviar_correo` está **antes** de `Marcar_notificado`
- [ ] `Marcar_notificado` corre solo si el correo salió bien
- [ ] Las expresiones de `MedEquipo` y `MedTipo` usan la guarda
      `startsWith(string(X), '{')`
- [ ] Flow exportado como `.zip` y guardado en esta carpeta

---

## Pruebas

No se puede esperar treinta días para ver si funciona. Se fuerza:

1. Subí un PDF de prueba con la app, con **vigencia de 1 mes**.
2. En SharePoint, editá a mano su **Fecha de vencimiento** y ponela a cinco días
   de hoy. Dejá **Último aviso enviado** vacío.
3. En el flow: **Ejecutar** → tendría que llegar un correo con la franja naranja
   y el hito `d7` escrito en la columna.
4. **Volvé a ejecutarlo sin tocar nada.** No tiene que llegar ningún correo — así
   se comprueba que la marca evita el envío diario.
5. Cambiá la fecha de vencimiento a ayer y limpiá **Último aviso enviado**.
   Ejecutá: correo con la franja roja y `vencido-<año>-<semana>` en la columna.
6. Borrá el PDF de prueba.

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

Conviene mirar la pestaña **Análisis** del flow cada tanto: si la tasa de éxito
cae, algo se rompió — casi siempre la conexión de SharePoint o de Outlook, que
expira sola y se arregla en **Conexiones → Reparar**.
