# Control de Mediciones Higiénicas — LUZ y RUIDO

Aplicación web para cargar estudios de iluminación y ruido a la biblioteca
**Documentos QHSE** de SharePoint, con fecha de vencimiento por documento y aviso
automático por correo cuando una medición está por vencer.

- **Sitio publicado:** https://apu242007.github.io/control-de-mediciones-higienicas/
- **Biblioteca destino:** `Documentos QHSE` → `16 - Mediciones Higiénicas LUZ y RUIDO`
- **Aviso de vencimientos:** jcastro@tackertools.com

> Los PDF viven **únicamente en SharePoint**. Este repositorio no contiene ni un
> solo documento, y el `.gitignore` está armado para que siga siendo así.

---

## Cómo funciona

```
Navegador (GitHub Pages, sitio estático)
        │  POST con el PDF en base64 + los datos del formulario
        ▼
Power Automate — flow MED-API
        │  valida el PIN contra SharePoint (con bloqueo por intentos)
        ├──▶ crea la carpeta si falta y guarda el PDF
        └──▶ escribe Equipo, Cliente, Tipo, Fecha y Vencimiento en las columnas

Power Automate — flow MED-Alertas  (corre solo, 08:00 todos los días)
        └──▶ un correo por cada medición a 30, 15 y 7 días del vencimiento,
             y uno por semana mientras siga vencida
```

### Dónde queda cada archivo

```
Documentos QHSE
└── 16 - Mediciones Higiénicas LUZ y RUIDO
    ├── Mediciones de luz
    │   ├── Tacker 07
    │   │   ├── 2025
    │   │   └── 2026
    │   │       └── POSGI001-A7-1 Iluminación - TKR 07 - YPF - 2026-09-17.pdf
    │   └── Mase 03
    └── Medición de Ruido
        └── …
```

La app arma el nombre del archivo sola, con el código de procedimiento que ya se
usa (`POSGI001-A7-1` para iluminación, `POSGI001-A6-2` para ruido). No hace falta
cargarlo a mano ni acordarse del formato.

---

## Puesta en marcha

Hacé los pasos **en este orden**. Si te salteás el 1 o el 4, la app no va a dar
error: los datos simplemente no van a aparecer, que es mucho peor.

### 1 · Columnas en SharePoint

```powershell
cd sharepoint
.\Setup-Columnas-Mediciones.ps1
```

La primera vez te va a mostrar un código para pegar en
https://microsoft.com/devicelogin. Entrá con tu cuenta `@tackertools.com`.
Después guarda la sesión cifrada y no vuelve a pedirte el código por unos noventa
días.

El script crea, en la biblioteca `Documentos QHSE`:

| Columna | Tipo | Para qué |
|---|---|---|
| Equipo | Elección | Tacker 01–11, Mase 01–04 |
| Cliente | Texto | operadora |
| Tipo de medición | Elección | Iluminación / Ruido |
| Fecha de medición | Fecha | cuándo se midió |
| Fecha de vencimiento | Fecha, **indexada** | la que dispara el aviso |
| Vigencia (meses) | Número | plazo aplicado |
| Último aviso enviado | Texto | lo escribe el flow — no editar a mano |

Y una lista `MedicionesConfig` con los dos PIN y el contador de intentos fallidos.

**Al terminar te muestra los PIN generados. Anotalos ahí mismo: no quedan
guardados en ningún archivo.** Los podés cambiar cuando quieras editando la
columna *Valor* de esa lista.

Se puede correr todas las veces que quieras: lo que ya existe lo saltea.

> `Cliente` es una columna de **texto**, no de elección, a propósito: la app
> permite escribir una operadora que no esté en la lista sin esperar un
> despliegue. Una columna de elección descartaría ese valor **en silencio** — el
> flow terminaría bien y la columna quedaría vacía.

### 2 · Flow `MED-API`

Seguí [`power-automate/Flow-1-MED-API.md`](power-automate/Flow-1-MED-API.md).
Está paso a paso, con el nombre exacto de cada campo de la interfaz.

Al guardar, copiá la **URL del disparador** (aparece en la tarjeta del primer
paso). La necesitás en el paso 4.

### 3 · Flow `MED-Alertas`

Seguí [`power-automate/Flow-2-MED-Alertas.md`](power-automate/Flow-2-MED-Alertas.md).
Este no tiene URL: se dispara solo, todos los días a las 8.

### 4 · Secrets de GitHub

En el repositorio: **Settings → Secrets and variables → Actions → New repository secret**

| Nombre | Valor |
|---|---|
| `URL_FLOW` | la URL del disparador del flow `MED-API` |
| `APP_KEY` | una cadena cualquiera, larga y sin espacios. La misma que pusiste en `Verificar_clave` |

### 5 · Activar Pages

**Settings → Pages → Source: GitHub Actions**

Después, cualquier `push` a `main` publica el sitio. También se puede lanzar a
mano desde la pestaña **Actions**.

### 6 · Probar de punta a punta

Con un PDF real, desde el celular y desde la PC:

- [ ] Cargar una medición → aparece en la carpeta correcta, con las columnas cargadas
- [ ] Cargar una segunda a la misma carpeta → funciona igual (la carpeta ya existe)
- [ ] Buscarla en el buscador → aparece con el semáforo correcto
- [ ] Descargarla → el PDF abre bien y pesa lo mismo que el original
- [ ] Meter un PIN equivocado → dice «PIN incorrecto»
- [ ] Meterlo mal cinco veces → queda bloqueado unos minutos
- [ ] Forzar el flow de alertas (ver el paso *Pruebas* de su documento) → llega el correo

---

## Mantenimiento

### Agregar un equipo o una operadora

Los dos están en [`web-app/assets/catalogos.js`](web-app/assets/catalogos.js).
Editás, `push`, y en un minuto está publicado.

**Para los equipos hay un segundo paso:** agregar el valor también a la columna de
elección `Equipo` en SharePoint (en el script, o a mano desde la biblioteca).
Si no, SharePoint **descarta ese valor sin avisar** y la columna queda vacía. El
flow no falla, el archivo se sube, y el dato se pierde.

Las operadoras no tienen ese problema: `Cliente` es una columna de texto.

### Cambiar los plazos de vigencia

También en `catalogos.js`, en `VIGENCIAS`. Hoy están 12, 6, 3 y 1 mes, más la
opción de cargar la fecha a mano para los clientes que piden medición pozo a pozo
con un calendario propio.

### Cambiar los PIN

En SharePoint, lista `MedicionesConfig`, columna **Valor**. Toma efecto en la
llamada siguiente: no hay que volver a desplegar nada.

Si cambiás un PIN, poné **Intentos fallidos** en `0` y borrá **Bloqueado hasta**.

### Cambiar quién recibe los avisos

En el flow `MED-Alertas`, campo **Para** de la acción `Enviar_correo`. No está en
el código de la app justamente para que no quede expuesto en el sitio público.

### Después de tocar el sitio

Subí el número de `CACHE` en
[`web-app/assets/sw.js`](web-app/assets/sw.js). Si no lo hacés, los navegadores
que ya entraron van a seguir mostrando la versión vieja durante días.

### Después de tocar un flow

Exportalo (`… → Exportar → Paquete .zip`), guardá el `.zip` en
`power-automate/` y actualizá el `.md`. Power Automate no guarda los flows como
texto, así que esos dos archivos son el único respaldo y la única documentación.

---

## Seguridad — lo que este diseño sí y no protege

Vale la pena tenerlo escrito, para que no sea una sorpresa en una auditoría.

**El endpoint es público.** Tiene que serlo: el navegador lo llama sin que nadie
inicie sesión. Ni la URL del flow ni `APP_KEY` son secretos — los dos viajan
dentro del JavaScript que descarga cualquier visitante, y se leen con abrir las
herramientas de desarrollo. Guardarlos como *secrets* de GitHub los mantiene
fuera del código fuente, no fuera del sitio publicado.

**Lo que realmente controla el acceso es el PIN**, y lo controla porque se valida
**dentro del flow**, contra SharePoint, con contador de intentos y bloqueo de
quince minutos al quinto fallo. Sin ese contador, cuatro dígitos son diez mil
combinaciones y se agotan por fuerza bruta en minutos.

Hay dos PIN separados, así se puede dar acceso de consulta a alguien sin
habilitarlo a cargar documentos.

**Repartilos por un canal distinto al del link.** Si el link y el PIN viajan en el
mismo correo, el PIN no agrega nada: cualquiera que lo reciba reenviado tiene los
dos. El link por mail, el PIN por teléfono.

**Límite conocido y aceptado:** quien tenga el link y el PIN puede operar. No hay
identidad por persona. La contención es la trazabilidad — SharePoint registra
cada archivo con su fecha y su autor de sistema — y el acuerdo interno sobre quién
tiene el PIN, no un control de acceso por usuario.

Si en algún momento hace falta identidad real por persona, el camino es cambiar a
inicio de sesión con Microsoft 365 (Entra ID + Microsoft Graph). Eso obliga a
todos a iniciar sesión, que es exactamente lo que este diseño quiso evitar.

**Tamaño de archivo:** el tope del cliente son 18 MB y avisa arriba de 8 MB. Al
enviarse, un PDF crece cerca de un 33 % por la codificación, y Power Automate
corta la ejecución a los ~110 segundos. Los estudios de este historial van de
0,3 a 9,5 MB, así que entran; pero un PDF muy pesado conviene comprimirlo antes o
subirlo directo por SharePoint.

---

## Estructura del repositorio

```
├── web-app/                      Sitio estático — es lo que se publica
│   ├── index.html                pantalla de carga
│   ├── buscar.html               pantalla de búsqueda y descarga
│   └── assets/
│       ├── catalogos.js          ← equipos, clientes, tipos, vigencias
│       ├── config.js             ← marcadores que rellena GitHub Actions
│       ├── api.js                cliente del flow
│       ├── app-carga.js          lógica de la pantalla de carga
│       ├── app-buscar.js         lógica del buscador
│       ├── estilos.css
│       ├── sw.js                 ← subir CACHE en cada cambio
│       └── sw-registro.js
├── sharepoint/
│   └── Setup-Columnas-Mediciones.ps1
├── power-automate/
│   ├── Flow-1-MED-API.md         diseño del flow de la app
│   └── Flow-2-MED-Alertas.md     diseño del flow de avisos
└── .github/workflows/
    └── deploy-pages.yml
```

No hay `npm install`, ni compilación, ni dependencias.

### Pruebas

```powershell
npm test
```

82 pruebas, sin dependencias — usan el ejecutor propio de Node. Cubren la
aritmética de fechas (el desborde de día al sumar meses, el corrimiento por zona
horaria), el armado y saneado del nombre de archivo, la validación del
formulario, el contrato del cliente del flow, y la integridad entre el HTML y el
JS: que cada `id` que el JavaScript busca exista de verdad, que ningún módulo lea
una global de configuración, y que todo lo que el service worker precachea
exista.

Corren también en CI, y si fallan el despliegue no se ejecuta.

**Lo que las pruebas NO cubren:** que la pantalla se vea y se comporte bien.
Eso hay que mirarlo en un navegador, y conviene hacerlo en un celular real —
varias cosas (el ícono de iOS, la cámara, el comportamiento al bloquear la
pantalla) no se reproducen en el emulador del navegador. El flow y SharePoint
tampoco se pueden probar desde acá: para eso está la lista del paso 6.

### Probar el sitio en tu máquina

Son archivos estáticos que el navegador lee tal como están:

```powershell
cd web-app
python -m http.server 8080
```

Y abrí http://localhost:8080. Sin la URL del flow configurada, el sitio arranca en
**modo demo**: valida todo el formulario y arma el nombre del archivo, pero no
envía nada. El aviso amarillo arriba lo deja claro.

---

## Cuando algo no funciona

**Antes de suponer que hay un error en el código**, mirá el **Historial de
ejecuciones** del flow en `make.powerautomate.com`. Ahí está la corrida, la acción
que falló y el mensaje exacto del motor. Leerlo cuesta un minuto; adivinar cuesta
una vuelta entera de corregir, desplegar y volver a probar.

| Lo que ves | Casi siempre es |
|---|---|
| Aparece el aviso de «modo demo» en el sitio publicado | falta el secret `URL_FLOW`, o el workflow no llegó a correr |
| «Sin conexión con el servidor» | la URL del flow quedó mal copiada, o el flow está desactivado |
| «Solicitud no autorizada» (401) sin haber tocado el PIN | `APP_KEY` no coincide con lo que espera `Verificar_clave` en el flow |
| El buscador anda con cero resultados y falla en cuanto hay uno | falta la guarda de tipo en el `Seleccionar` del flow — está explicado en su documento |
| El PDF se sube pero no abre | el campo *Contenido del archivo* del flow; son tres trampas, están en el documento del flow |
| El archivo sube pero las columnas quedan vacías | un valor que no está en la columna de elección de SharePoint |
| No llega ningún aviso de vencimiento | la conexión de Outlook o de SharePoint expiró → **Conexiones → Reparar** |
| Arreglaste algo, desplegaste, y se sigue viendo igual | el service worker sirve la versión vieja. Subí `CACHE` en `sw.js` |

Los dos documentos de `power-automate/` tienen cada uno su propia tabla de errores
y su lista de verificación.
