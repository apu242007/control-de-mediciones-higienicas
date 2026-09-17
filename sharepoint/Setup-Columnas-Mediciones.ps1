<#
===============================================================================
 Setup-Columnas-Mediciones.ps1

 Crea (de forma idempotente) las columnas que la app necesita en la biblioteca
 "Documentos QHSE", y la lista de configuracion que guarda el PIN.

 Se puede correr todas las veces que quieras: si una columna ya existe, la
 saltea. No borra ni sobrescribe nada.

 USO
   .\Setup-Columnas-Mediciones.ps1
   .\Setup-Columnas-Mediciones.ps1 -PinCarga 4821 -PinConsulta 1907

 AUTENTICACION
   Flujo de codigo de dispositivo contra el cliente de primera parte de
   SharePoint (ya consentido en el tenant: no hace falta permiso de admin).
   La primera vez te va a pedir abrir una URL y pegar un codigo. Despues
   guarda el refresh token cifrado en %LOCALAPPDATA% y ya no vuelve a pedirlo
   por unos 90 dias.

 IMPORTANTE: guardar este archivo SIEMPRE como UTF-8 CON BOM. PowerShell 5.1
 lee los .ps1 como ANSI si no tienen BOM, y los acentos rompen el parser.
===============================================================================
#>

[CmdletBinding()]
param(
    [string] $Hostname = "tackersrl505.sharepoint.com",
    [string] $RutaSitio = "/sites/QHSE",
    [string] $RutaBiblioteca = "/sites/QHSE/Documentos QHSE",
    [string] $ListaConfig = "MedicionesConfig",

    # PIN iniciales. Si no los pasas, el script genera dos al azar y los
    # muestra al final. Anotalos: no quedan en ningun archivo.
    [string] $PinCarga = "",
    [string] $PinConsulta = "",

    [switch] $ForzarLogin
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ClienteSP = "9bc3ab49-b65d-410a-85ad-de819febfddc"  # SharePoint Online Management Shell
$Recurso   = "https://$Hostname"
$ApiSitio  = "$Recurso$RutaSitio/_api"
$RutaToken = Join-Path $env:LOCALAPPDATA "mediciones-qhse.refreshtoken"

# ---------------------------------------------------------------------------
# Autenticacion
# ---------------------------------------------------------------------------

function Save-RefreshToken {
    param([string] $Token)
    try {
        Add-Type -AssemblyName System.Security
        $bytes = [Text.Encoding]::UTF8.GetBytes($Token)
        $prot  = [Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes($RutaToken, $prot)
    } catch {
        Write-Host "  (aviso) no se pudo guardar el token: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Read-RefreshToken {
    if (-not (Test-Path -LiteralPath $RutaToken)) { return $null }
    try {
        Add-Type -AssemblyName System.Security
        $prot  = [IO.File]::ReadAllBytes($RutaToken)
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $prot, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($bytes)
    } catch { return $null }
}

function Get-TokenPorDispositivo {
    $dc = Invoke-RestMethod -UseBasicParsing -Method POST `
        -Uri "https://login.microsoftonline.com/common/oauth2/devicecode" `
        -Body "client_id=$ClienteSP&resource=$Recurso"

    Write-Host ""
    Write-Host "  ==================================================" -ForegroundColor Cyan
    Write-Host "   1. Abri:   https://microsoft.com/devicelogin"      -ForegroundColor Cyan
    Write-Host "   2. Codigo: $($dc.user_code)"                       -ForegroundColor Yellow
    Write-Host "   3. Entra con tu cuenta @tackertools.com"           -ForegroundColor Cyan
    Write-Host "  ==================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Esperando (hasta 15 minutos)..." -NoNewline

    $limite = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $limite) {
        Start-Sleep -Seconds 5
        try {
            $t = Invoke-RestMethod -UseBasicParsing -Method POST `
                -Uri "https://login.microsoftonline.com/common/oauth2/token" `
                -Body ("grant_type=urn:ietf:params:oauth:grant-type:device_code" +
                       "&client_id=$ClienteSP&code=$($dc.device_code)")
            Write-Host " listo." -ForegroundColor Green
            if ($t.refresh_token) { Save-RefreshToken $t.refresh_token }
            return $t.access_token
        } catch {
            $msg = ""
            try { $msg = $_.ErrorDetails.Message } catch {}
            if ($msg -notmatch "authorization_pending") {
                Write-Host ""
                throw "Fallo la autenticacion: $msg"
            }
            Write-Host "." -NoNewline
        }
    }
    Write-Host ""
    throw "Se agoto el tiempo de espera del codigo de dispositivo."
}

function Get-Token {
    if (-not $ForzarLogin) {
        $rt = Read-RefreshToken
        if ($rt) {
            try {
                $t = Invoke-RestMethod -UseBasicParsing -Method POST `
                    -Uri "https://login.microsoftonline.com/common/oauth2/token" `
                    -Body "grant_type=refresh_token&client_id=$ClienteSP&refresh_token=$rt&resource=$Recurso"
                if ($t.refresh_token) { Save-RefreshToken $t.refresh_token }
                Write-Host "  Sesion reutilizada (sin pedir codigo)." -ForegroundColor DarkGray
                return $t.access_token
            } catch {
                Write-Host "  El token guardado ya no sirve. Pido uno nuevo." -ForegroundColor DarkYellow
            }
        }
    }
    return Get-TokenPorDispositivo
}

# ---------------------------------------------------------------------------
# Cliente REST
# ---------------------------------------------------------------------------

$script:Token = $null

function Invoke-SP {
    param(
        [ValidateSet("GET","POST")] [string] $Method = "GET",
        [Parameter(Mandatory=$true)] [string] $Uri,
        [string] $Body,
        [hashtable] $ExtraHeaders,
        [int] $Intentos = 3
    )

    for ($i = 1; $i -le $Intentos; $i++) {
        $h = @{
            Authorization = "Bearer $($script:Token)"
            Accept        = "application/json;odata=nometadata"
        }
        if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }

        try {
            if ($Body) {
                # El cuerpo va SIEMPRE como bytes UTF-8. Invoke-RestMethod con
                # un string manda ISO-8859-1, y cualquier acento en un titulo o
                # en una opcion hace que SharePoint responda 400 con
                # "Unable to translate bytes [F3]...".
                $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
                if (-not $h.ContainsKey("Content-Type")) {
                    $h["Content-Type"] = "application/json;odata=nometadata;charset=utf-8"
                }
                return Invoke-RestMethod -UseBasicParsing -Method $Method -Uri $Uri -Headers $h -Body $bytes
            }
            return Invoke-RestMethod -UseBasicParsing -Method $Method -Uri $Uri -Headers $h
        } catch {
            $codigo = 0
            try { $codigo = [int]$_.Exception.Response.StatusCode } catch {}

            # SharePoint devuelve 401 esporadico en las primeras llamadas con un
            # token recien emitido. Renovar y reintentar.
            if ($codigo -eq 401 -and $i -lt $Intentos) {
                Start-Sleep -Milliseconds 800
                $script:Token = Get-Token
                continue
            }
            if (($codigo -eq 429 -or $codigo -eq 503) -and $i -lt $Intentos) {
                Start-Sleep -Seconds 3
                continue
            }
            throw
        }
    }
}

function Get-ErrorSP {
    param($Excepcion)
    try {
        $sr = New-Object IO.StreamReader($Excepcion.Exception.Response.GetResponseStream())
        $txt = $sr.ReadToEnd()
        $sr.Close()
        $j = $txt | ConvertFrom-Json
        if ($j.error.message.value) { return $j.error.message.value }
        if ($j.'odata.error'.message.value) { return $j.'odata.error'.message.value }
        return $txt
    } catch { return $Excepcion.Exception.Message }
}

# ---------------------------------------------------------------------------
# Columnas
# ---------------------------------------------------------------------------

function Add-Columna {
    <#
      Crea una columna por createfieldasxml.

      Es el endpoint mas confiable: permite fijar el nombre interno y el
      nombre visible por separado (asi los acentos quedan solo en el visible,
      donde no molestan) y setear Indexed en el mismo XML.

      OJO: el endpoint se llama createfieldasxml. `addfieldasxml` es el nombre
      del metodo en CSOM/PnP y por REST devuelve un 404 disfrazado
      ("No se encuentra el recurso para la solicitud addfieldasxml").
    #>
    param(
        [Parameter(Mandatory=$true)] [string] $UrlLista,
        [Parameter(Mandatory=$true)] [string] $NombreInterno,
        [Parameter(Mandatory=$true)] [string] $NombreVisible,
        [Parameter(Mandatory=$true)] [string] $Tipo,
        [string[]] $Opciones,
        [switch] $Indexada,
        [string] $Descripcion = "",
        [string] $Formato = ""
    )

    # ¿Ya existe?
    try {
        Invoke-SP -Uri "$UrlLista/fields/getbyinternalnameortitle('$NombreInterno')" | Out-Null
        Write-Host "  = $NombreVisible ($NombreInterno) ya existe" -ForegroundColor DarkGray
        return $true
    } catch {
        # no existe: seguimos
    }

    $esc = {
        param($t)
        [string]$t -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&apos;'
    }

    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<Field Type='$Tipo'")
    [void]$sb.Append(" Name='$NombreInterno'")
    [void]$sb.Append(" StaticName='$NombreInterno'")
    [void]$sb.Append(" DisplayName='$(& $esc $NombreVisible)'")
    if ($Descripcion) { [void]$sb.Append(" Description='$(& $esc $Descripcion)'") }
    if ($Indexada)    { [void]$sb.Append(" Indexed='TRUE'") }

    switch ($Tipo) {
        "DateTime" {
            [void]$sb.Append(" Format='DateOnly'")
            [void]$sb.Append(" FriendlyDisplayFormat='Disabled'")
        }
        "Number" {
            [void]$sb.Append(" Decimals='0'")
            [void]$sb.Append(" Min='0'")
        }
        "Choice" {
            [void]$sb.Append(" Format='Dropdown'")
            [void]$sb.Append(" FillInChoice='FALSE'")
        }
    }
    if ($Formato) { [void]$sb.Append(" $Formato") }
    [void]$sb.Append(">")

    if ($Tipo -eq "Choice" -and $Opciones) {
        [void]$sb.Append("<CHOICES>")
        foreach ($o in $Opciones) { [void]$sb.Append("<CHOICE>$(& $esc $o)</CHOICE>") }
        [void]$sb.Append("</CHOICES>")
    }
    [void]$sb.Append("</Field>")

    # Options 28 = AddToDefaultContentType(4) + AddFieldInternalNameHint(8)
    #            + AddFieldToDefaultView(16)
    $payload = @{
        parameters = @{
            SchemaXml = $sb.ToString()
            Options   = 28
        }
    } | ConvertTo-Json -Depth 6 -Compress

    try {
        Invoke-SP -Method POST -Uri "$UrlLista/fields/createfieldasxml" -Body $payload | Out-Null
        Write-Host "  + $NombreVisible ($NombreInterno) creada" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  x $NombreVisible ($NombreInterno) FALLO: $(Get-ErrorSP $_)" -ForegroundColor Red
        return $false
    }
}

# ---------------------------------------------------------------------------
# Programa
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Mediciones Higienicas - alta de columnas en SharePoint" -ForegroundColor White
Write-Host "  Sitio:       $Recurso$RutaSitio"
Write-Host "  Biblioteca:  $RutaBiblioteca"
Write-Host ""

$script:Token = Get-Token

# --- Verificar que el token sea de ESTE tenant ---------------------------
# Un usuario con varias cuentas M365 puede tener cacheado un refresh token de
# otro tenant. El sintoma seria 401 en TODOS los endpoints, incluso /_api/web,
# y desorienta bastante. Mejor detectarlo aca.
try {
    $web = Invoke-SP -Uri "$ApiSitio/web?`$select=Title,Url"
    Write-Host "  Conectado a: $($web.Title)" -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "  No se pudo leer el sitio. Casi siempre es una de dos cosas:" -ForegroundColor Red
    Write-Host "    - El token es de otro tenant  -> corre con -ForzarLogin" -ForegroundColor Red
    Write-Host "    - No tenes acceso al sitio    -> pedi permiso en /sites/QHSE" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Detalle: $(Get-ErrorSP $_)" -ForegroundColor DarkRed
    exit 1
}

# --- Resolver la biblioteca por URL, no por titulo -----------------------
# getbytitle() falla seguido: el nombre que se ve en la URL no siempre coincide
# con el titulo interno de la biblioteca.
$encUrl = $RutaBiblioteca -replace ' ', '%20'
$urlBib = "$ApiSitio/web/GetList('$encUrl')"

try {
    $bib = Invoke-SP -Uri "$($urlBib)?`$select=Title,Id,ItemCount,BaseTemplate"
    Write-Host "  Biblioteca:  $($bib.Title) — $($bib.ItemCount) elementos" -ForegroundColor Green
    if ($bib.BaseTemplate -ne 101) {
        Write-Host "  (aviso) BaseTemplate=$($bib.BaseTemplate); se esperaba 101 (biblioteca de documentos)." -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "  No se encontro la biblioteca en '$RutaBiblioteca'." -ForegroundColor Red
    Write-Host "  Detalle: $(Get-ErrorSP $_)" -ForegroundColor DarkRed
    exit 1
}

# --- Columnas de la biblioteca -------------------------------------------
Write-Host ""
Write-Host "  Columnas de la biblioteca" -ForegroundColor White

# Nombres internos con prefijo Med: evita choques con columnas ocultas que
# SharePoint ya trae (Categoria es el caso clasico) y deja los acentos solo
# en el nombre visible.
$ok = $true
$ok = (Add-Columna -UrlLista $urlBib -NombreInterno "MedEquipo" `
        -NombreVisible "Equipo" -Tipo "Choice" -Indexada `
        -Descripcion "Equipo al que corresponde la medicion." `
        -Opciones @(
            "Tacker 01","Tacker 05","Tacker 06","Tacker 07","Tacker 08",
            "Tacker 10","Tacker 11",
            "Mase 01","Mase 02","Mase 03","Mase 04"
        )) -and $ok

# Cliente es Text, no Choice: la app deja escribir una operadora nueva sin
# esperar un deploy. Una columna Choice descartaria ese valor EN SILENCIO.
$ok = (Add-Columna -UrlLista $urlBib -NombreInterno "MedCliente" `
        -NombreVisible "Cliente" -Tipo "Text" -Indexada `
        -Descripcion "Operadora o cliente para el que se hizo la medicion.") -and $ok

$ok = (Add-Columna -UrlLista $urlBib -NombreInterno "MedTipo" `
        -NombreVisible "Tipo de medición" -Tipo "Choice" -Indexada `
        -Descripcion "Iluminacion o ruido." `
        -Opciones @("Iluminación","Ruido")) -and $ok

$ok = (Add-Columna -UrlLista $urlBib -NombreInterno "MedFechaMedicion" `
        -NombreVisible "Fecha de medición" -Tipo "DateTime" -Indexada `
        -Descripcion "Fecha en que se realizo la medicion en campo.") -and $ok

# Indexada si o si: el flow de alertas filtra por esta columna todos los dias.
# Sin indice, en cuanto la biblioteca pase los 5000 elementos el filtro falla.
$ok = (Add-Columna -UrlLista $urlBib -NombreInterno "MedFechaVencimiento" `
        -NombreVisible "Fecha de vencimiento" -Tipo "DateTime" -Indexada `
        -Descripcion "Fecha en que vence la vigencia del estudio.") -and $ok

$ok = (Add-Columna -UrlLista $urlBib -NombreInterno "MedVigenciaMeses" `
        -NombreVisible "Vigencia (meses)" -Tipo "Number" `
        -Descripcion "Plazo de vigencia aplicado. Vacio = fecha cargada a mano.") -and $ok

$ok = (Add-Columna -UrlLista $urlBib -NombreInterno "MedAlertaEnviada" `
        -NombreVisible "Último aviso enviado" -Tipo "Text" `
        -Descripcion "Hito de alerta ya notificado (30/15/7/vencido). Lo escribe el flow: no editar a mano.") -and $ok

# --- Lista de configuracion (PIN) ----------------------------------------
Write-Host ""
Write-Host "  Lista de configuración ($ListaConfig)" -ForegroundColor White

$urlCfg = "$ApiSitio/web/lists/getbytitle('$ListaConfig')"
$existeCfg = $false
try {
    Invoke-SP -Uri "$($urlCfg)?`$select=Title" | Out-Null
    $existeCfg = $true
    Write-Host "  = la lista ya existe" -ForegroundColor DarkGray
} catch {
    # El POST a /web/lists esta bloqueado en algunos tenants y permitido en
    # otros. Cuesta diez segundos probarlo, asi que se prueba.
    $cuerpo = @{
        Title        = $ListaConfig
        Description  = "Configuracion de la app de mediciones higienicas. No borrar."
        BaseTemplate = 100
    } | ConvertTo-Json -Compress
    try {
        Invoke-SP -Method POST -Uri "$ApiSitio/web/lists" -Body $cuerpo | Out-Null
        Write-Host "  + lista creada" -ForegroundColor Green
        $existeCfg = $true
    } catch {
        Write-Host "  x no se pudo crear por REST: $(Get-ErrorSP $_)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Creala a mano y volve a correr el script:" -ForegroundColor Yellow
        Write-Host "    $Recurso$RutaSitio/_layouts/15/viewlsts.aspx" -ForegroundColor Yellow
        Write-Host "    + Nuevo -> Lista -> En blanco -> nombre: $ListaConfig" -ForegroundColor Yellow
        Write-Host ""
    }
}

if ($existeCfg) {
    $ok = (Add-Columna -UrlLista $urlCfg -NombreInterno "CfgValor" `
            -NombreVisible "Valor" -Tipo "Text" `
            -Descripcion "Valor del parametro.") -and $ok
    $ok = (Add-Columna -UrlLista $urlCfg -NombreInterno "CfgFallidos" `
            -NombreVisible "Intentos fallidos" -Tipo "Number" `
            -Descripcion "Intentos errados consecutivos. El flow lo resetea al acertar.") -and $ok
    $ok = (Add-Columna -UrlLista $urlCfg -NombreInterno "CfgBloqueadoHasta" `
            -NombreVisible "Bloqueado hasta" -Tipo "DateTime" `
            -Descripcion "Mientras sea futura, el flow rechaza todo con 429.") -and $ok

    # --- Filas de PIN ---
    Write-Host ""
    Write-Host "  PIN de acceso" -ForegroundColor White

    if (-not $PinCarga)    { $PinCarga    = (Get-Random -Minimum 1000 -Maximum 9999).ToString() }
    if (-not $PinConsulta) { $PinConsulta = (Get-Random -Minimum 1000 -Maximum 9999).ToString() }

    $generados = @()
    foreach ($par in @(
        @{ Clave = "PIN_CARGA";    Pin = $PinCarga;    Que = "subir documentos" },
        @{ Clave = "PIN_CONSULTA"; Pin = $PinConsulta; Que = "buscar y descargar" }
    )) {
        $filtro = "`$filter=Title eq '$($par.Clave)'&`$select=Id,Title"
        $yaEsta = $false
        try {
            $r = Invoke-SP -Uri "$urlCfg/items?$filtro"
            if ($r.value -and $r.value.Count -gt 0) { $yaEsta = $true }
        } catch {}

        if ($yaEsta) {
            Write-Host "  = $($par.Clave) ya está configurado (no se toca)" -ForegroundColor DarkGray
            continue
        }

        $fila = @{
            Title       = $par.Clave
            CfgValor    = $par.Pin
            CfgFallidos = 0
        } | ConvertTo-Json -Compress
        try {
            Invoke-SP -Method POST -Uri "$urlCfg/items" -Body $fila | Out-Null
            Write-Host "  + $($par.Clave) creado" -ForegroundColor Green
            $generados += $par
        } catch {
            Write-Host "  x $($par.Clave) FALLO: $(Get-ErrorSP $_)" -ForegroundColor Red
            $ok = $false
        }
    }

    if ($generados.Count -gt 0) {
        Write-Host ""
        Write-Host "  ==================================================" -ForegroundColor Yellow
        Write-Host "   ANOTÁ ESTOS PIN AHORA. No quedan en ningún archivo." -ForegroundColor Yellow
        foreach ($g in $generados) {
            Write-Host ("   {0,-14} {1}   ({2})" -f $g.Clave, $g.Pin, $g.Que) -ForegroundColor White
        }
        Write-Host "  ==================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   Los podés cambiar cuando quieras desde la lista" -ForegroundColor DarkGray
        Write-Host "   $ListaConfig, en la columna Valor." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "   Repartilos por un canal DISTINTO al del link de la app:" -ForegroundColor DarkYellow
        Write-Host "   si el link y el PIN viajan en el mismo mail, el PIN no suma nada." -ForegroundColor DarkYellow
    }
}

# --- Cierre ---------------------------------------------------------------
Write-Host ""
if ($ok) {
    Write-Host "  Listo. Todas las columnas están en su lugar." -ForegroundColor Green
    Write-Host "  Siguiente paso: armar los flows (ver power-automate/)." -ForegroundColor Green
} else {
    Write-Host "  Terminó con errores. Revisá las líneas en rojo de arriba." -ForegroundColor Red
}
Write-Host ""
exit $(if ($ok) { 0 } else { 1 })
