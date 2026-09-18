<#
===============================================================================
 Cargar-Historico.ps1

 Sube TODOS los PDF que ya existen en las carpetas locales de mediciones a la
 biblioteca Documentos QHSE, con Equipo, Tipo de medición y Fecha de medición
 cargados en sus columnas. Cliente queda vacío a proposito: se empieza a
 completar cuando el personal cargue desde la app.

 El tipo de medicion sale de la carpeta CONTENEDORA local (Mediciones de luz /
 Medicion de Ruido), no del nombre del archivo: varios archivos historicos
 tienen "Ruido" en el nombre estando guardados en la carpeta de luz, y
 viceversa. Se respeta donde esta guardado, y se reporta la discrepancia al
 final para que se revise a mano.

 La fecha se parseo a mano, archivo por archivo, leyendo el nombre real (no con
 un regex generico): los nombres son demasiado irregulares -- algunos traen
 dia-mes-año con guion o punto, otros solo "mes año", otros ningun dato de
 fecha. Donde no hay fecha reconocible, la columna queda vacia y el archivo cae
 en una carpeta "Sin fecha" dentro de su equipo, nunca se inventa un dato.

 USO
   .\Cargar-Historico.ps1                 # sube todo lo que falte
   .\Cargar-Historico.ps1 -SoloDiagnostico # no sube nada, solo lista que hay
   .\Cargar-Historico.ps1 -WhatIf          # simula, no escribe en SharePoint

 Requiere el token cacheado por Setup-Columnas-Mediciones.ps1 en:
   %LOCALAPPDATA%\mediciones-qhse.refreshtoken
 Si no esta o vencio, pide el mismo codigo de dispositivo.
===============================================================================
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Hostname = "tackersrl505.sharepoint.com",
    [string] $RutaSitio = "/sites/QHSE",
    [string] $LibraryId = "3bcd9efb-57ca-4acf-b841-2e2557cc09d5",
    [string] $RaizRelativa = "/sites/QHSE/Documentos QHSE/16 - Mediciones Higiénicas LUZ y RUIDO",
    [switch] $SoloDiagnostico,
    [switch] $ForzarLogin
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ClienteSP = "9bc3ab49-b65d-410a-85ad-de819febfddc"
$Recurso   = "https://$Hostname"
$ApiSitio  = "$Recurso$RutaSitio/_api"
$RutaToken = Join-Path $env:LOCALAPPDATA "mediciones-qhse.refreshtoken"
$RaizLocal = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# ---------------------------------------------------------------------------
# Autenticacion (mismo mecanismo que Setup-Columnas-Mediciones.ps1)
# ---------------------------------------------------------------------------

function Save-RefreshToken {
    param([string] $Token)
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($Token)
    $prot  = [Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($RutaToken, $prot)
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
    Write-Host "  1. Abri:   https://microsoft.com/devicelogin" -ForegroundColor Cyan
    Write-Host "  2. Codigo: $($dc.user_code)" -ForegroundColor Yellow
    Write-Host "  Esperando (hasta 15 min)..." -NoNewline
    $limite = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $limite) {
        Start-Sleep -Seconds 5
        try {
            $t = Invoke-RestMethod -UseBasicParsing -Method POST `
                -Uri "https://login.microsoftonline.com/common/oauth2/token" `
                -Body ("grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=$ClienteSP&code=$($dc.device_code)")
            Write-Host " listo." -ForegroundColor Green
            if ($t.refresh_token) { Save-RefreshToken $t.refresh_token }
            return $t.access_token
        } catch {
            $msg = ""
            try { $msg = $_.ErrorDetails.Message } catch {}
            if ($msg -notmatch "authorization_pending") { Write-Host ""; throw "Fallo la autenticacion: $msg" }
            Write-Host "." -NoNewline
        }
    }
    Write-Host ""; throw "Se agoto el tiempo de espera."
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
                Write-Host "  Sesion reutilizada (token cacheado)." -ForegroundColor DarkGray
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
        [ValidateSet("GET", "POST")] [string] $Method = "GET",
        [Parameter(Mandatory = $true)] [string] $Uri,
        [byte[]] $BodyBytes,
        [hashtable] $ExtraHeaders,
        [int] $Intentos = 3
    )
    for ($i = 1; $i -le $Intentos; $i++) {
        $h = @{ Authorization = "Bearer $($script:Token)"; Accept = "application/json;odata=nometadata" }
        if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }
        try {
            if ($BodyBytes) { return Invoke-RestMethod -UseBasicParsing -Method $Method -Uri $Uri -Headers $h -Body $BodyBytes }
            return Invoke-RestMethod -UseBasicParsing -Method $Method -Uri $Uri -Headers $h
        } catch {
            $codigo = 0
            try { $codigo = [int]$_.Exception.Response.StatusCode } catch {}
            if ($codigo -eq 401 -and $i -lt $Intentos) { Start-Sleep -Milliseconds 800; $script:Token = Get-Token; continue }
            if (($codigo -eq 429 -or $codigo -eq 503) -and $i -lt $Intentos) { Start-Sleep -Seconds 3; continue }
            throw
        }
    }
}

function Get-ErrorSP {
    param($Excepcion)
    try {
        $sr = New-Object IO.StreamReader($Excepcion.Exception.Response.GetResponseStream())
        $txt = $sr.ReadToEnd(); $sr.Close()
        $j = $txt | ConvertFrom-Json
        if ($j.error.message.value) { return $j.error.message.value }
        return $txt
    } catch { return $Excepcion.Exception.Message }
}

function ConvertTo-JsonUtf8Bytes {
    param($Objeto)
    return [Text.Encoding]::UTF8.GetBytes(($Objeto | ConvertTo-Json -Depth 10 -Compress))
}

# ---------------------------------------------------------------------------
# Tabla de mapeo: archivo local -> Tipo / Equipo / Año destino / Fecha
#
# Fecha en formato yyyy-MM-dd, o $null si el nombre no trae un dato de fecha
# confiable. AnioCarpeta es el año que se usa para la carpeta destino: viene
# de la fecha cuando existe, o de la subcarpeta local (2025, "Medición 2024")
# cuando el nombre no trae fecha pero la carpeta sí insinúa un año, o
# "Sin fecha" cuando no hay ningún dato.
#
# Advertencia: se anota cuando el nombre del archivo sugiere un tipo distinto
# al de la carpeta que lo contiene (ej. "Ruido" dentro de "Mediciones de luz").
# El tipo que se sube SIEMPRE es el de la carpeta contenedora: es el mismo
# criterio con que la app clasifica lo que carga el personal.
# ---------------------------------------------------------------------------

$Mapeo = @(
    # --- Mediciones de luz -> Iluminación --------------------------------
    @{ Local = "Mediciones de luz\Tacker 08\Verificación Iluminación TKR 8. 29-05-25.pdf"; Equipo = "Tacker 08"; Fecha = "2025-05-29" }
    @{ Local = "Mediciones de luz\Tacker 05\Medicion de Ruido TKR05 Agosto24.pdf"; Equipo = "Tacker 05"; Fecha = $null; Anio = "2024"; Advertencia = "nombre dice 'Ruido', carpeta es de luz" }
    @{ Local = "Mediciones de luz\Tacker 05\Medicion Iluminación TKR05 Agosto24.pdf"; Equipo = "Tacker 05"; Fecha = $null; Anio = "2024" }
    @{ Local = "Mediciones de luz\Tacker 08\Medicion Ruido TKR8- 31.01.2025.pdf"; Equipo = "Tacker 08"; Fecha = "2025-01-31"; Advertencia = "nombre dice 'Ruido', carpeta es de luz" }
    @{ Local = "Mediciones de luz\Mase 03\Medicion Iluminacion MASE03- 31.01.2025.pdf"; Equipo = "Mase 03"; Fecha = "2025-01-31" }
    @{ Local = "Mediciones de luz\Mase 03\Medicion Ruido MASE03- 31.01.2025.pdf"; Equipo = "Mase 03"; Fecha = "2025-01-31"; Advertencia = "nombre dice 'Ruido', carpeta es de luz" }
    @{ Local = "Mediciones de luz\Tacker 08\Medicion iluminacion TKR08- 31.01.2025.pdf"; Equipo = "Tacker 08"; Fecha = "2025-01-31" }
    @{ Local = "Mediciones de luz\Tacker 11\Medicion Ruido TKR11 Julio 2024.pdf"; Equipo = "Tacker 11"; Fecha = $null; Anio = "2024"; Advertencia = "nombre dice 'Ruido', carpeta es de luz" }
    @{ Local = "Mediciones de luz\Tacker 11\Medicion Iluminación TKR11 Julio 2024.pdf"; Equipo = "Tacker 11"; Fecha = $null; Anio = "2024" }
    @{ Local = "Mediciones de luz\Tacker 07\TKR 07. Estudio iluminación ..pdf"; Equipo = "Tacker 07"; Fecha = $null }
    @{ Local = "Mediciones de luz\Tacker 11\2025\TKR 11. Estudio de iluminación.pdf"; Equipo = "Tacker 11"; Fecha = $null; Anio = "2025" }
    @{ Local = "Mediciones de luz\Mase 02\Estudio iluminación MASE 02- 111125.pdf"; Equipo = "Mase 02"; Fecha = "2025-11-11" }
    @{ Local = "Mediciones de luz\Mase 04\POSGI001-A7-1 Estudio de Iluminación Mase 04- 22-01-2026..pdf"; Equipo = "Mase 04"; Fecha = "2026-01-22" }
    @{ Local = "Mediciones de luz\Mase 04\POSGI001-A7-1 Estudio de Iluminación Mase 04- 22-01-2026.pdf"; Equipo = "Mase 04"; Fecha = "2026-01-22" }
    @{ Local = "Mediciones de luz\Tacker 05\Estudio iluminación- TKR 05- Ce 1273.pdf"; Equipo = "Tacker 05"; Fecha = $null }
    @{ Local = "Mediciones de luz\Tacker 05\POSGI001-A7-1 Estudio de Iluminación TKR 05.pdf"; Equipo = "Tacker 05"; Fecha = $null }
    @{ Local = "Mediciones de luz\Tacker 08\Protocolo iluminacion TKR 08 - RDA 2108- 08-04-26.pdf"; Equipo = "Tacker 08"; Fecha = "2026-04-08" }
    @{ Local = "Mediciones de luz\Tacker 10\Estudio de luz - Tacker 10- 23-02-26.pdf"; Equipo = "Tacker 10"; Fecha = "2026-02-23" }
    @{ Local = "Mediciones de luz\Tacker 10\POSGI001-A7-1 Estudio de Iluminación TKR 10- 28-02-2025.pdf"; Equipo = "Tacker 10"; Fecha = "2025-02-28" }
    @{ Local = "Mediciones de luz\Tacker 11\TKR 11. Estudio de iluminación.pdf"; Equipo = "Tacker 11"; Fecha = $null }
    @{ Local = "Mediciones de luz\Mase 03\POSGI001-A7-1 Estudio de Iluminación Mase 03. 02-02-26.pdf"; Equipo = "Mase 03"; Fecha = "2026-02-02" }
    @{ Local = "Mediciones de luz\Tacker 01\Medición de iluminación TKR 01- MAYO 2025.pdf"; Equipo = "Tacker 01"; Fecha = $null; Anio = "2025" }
    @{ Local = "Mediciones de luz\Tacker 01\Medición de iluminación TKR 01- MAYO 2025..pdf"; Equipo = "Tacker 01"; Fecha = $null; Anio = "2025" }
    @{ Local = "Mediciones de luz\Tacker 06\estudio de iluminación TKR 06 - LLL 1605 - 08052025.pdf"; Equipo = "Tacker 06"; Fecha = "2025-05-08" }
    @{ Local = "Mediciones de luz\Tacker 06\Copia de POSGI001-A7-1 Estudio de Iluminación TKR 06- 23-05-2025.pdf"; Equipo = "Tacker 06"; Fecha = "2025-05-23" }
    @{ Local = "Mediciones de luz\Tacker 06\estudio de iluminación TKR06- LACH 604 - MAYO 2026.pdf"; Equipo = "Tacker 06"; Fecha = $null; Anio = "2026" }
    @{ Local = "Mediciones de luz\Tacker 06\estudio de iluminación TKR06- LACH 604.pdf"; Equipo = "Tacker 06"; Fecha = $null }
    @{ Local = "Mediciones de luz\Tacker 01\Medición de iluminación TKR 01- MAYO 2026.pdf_compressed.pdf"; Equipo = "Tacker 01"; Fecha = $null; Anio = "2026" }
    @{ Local = "Mediciones de luz\Tacker 07\POSGI001-A7-1 Estudio de Iluminación TKR 07- 09-11-25.pdf"; Equipo = "Tacker 07"; Fecha = "2025-11-09" }
    @{ Local = "Mediciones de luz\Tacker 01\Estudio de iluminación TKR 01- BMo 2024- Jun 26.pdf"; Equipo = "Tacker 01"; Fecha = $null; Anio = "2026" }
    @{ Local = "Mediciones de luz\Tacker 10\Estudio iluminación TKR 10- RDA 2013.pdf"; Equipo = "Tacker 10"; Fecha = $null }
    @{ Local = "Mediciones de luz\Tacker 08\Estudio iluminación laboral TKR 08 - 21-07-26.pdf"; Equipo = "Tacker 08"; Fecha = "2026-07-21" }
    @{ Local = "Mediciones de luz\Tacker 07\ESTUDIO DE ILUMINACION TKR 07 LAJE -11 23-7-26.pdf"; Equipo = "Tacker 07"; Fecha = "2026-07-23" }
    @{ Local = "Mediciones de luz\Mase 01\ESTUDIO DE ILUMINACION MASE01 8-9-26.pdf"; Equipo = "Mase 01"; Fecha = "2026-09-08" }
    @{ Local = "Mediciones de luz\Tacker 10\ESTUDIO DE ILUMINACION TKR 10 RDA-2030.pdf"; Equipo = "Tacker 10"; Fecha = $null }

    # --- Medición de Ruido -> Ruido ---------------------------------------
    @{ Local = "Medición de Ruido\Tacker 05\Medicion de Ruido TKR05 04-08-2024.pdf"; Equipo = "Tacker 05"; Fecha = "2024-08-04" }
    @{ Local = "Medición de Ruido\Tacker 08\Medicion Ruido TKR8- 31.01.2025.pdf"; Equipo = "Tacker 08"; Fecha = "2025-01-31" }
    @{ Local = "Medición de Ruido\Mase 03\Medicion Ruido MASE03- 31.01.2025.pdf"; Equipo = "Mase 03"; Fecha = "2025-01-31" }
    @{ Local = "Medición de Ruido\Tacker 11\Medición 2024\Medicion Ruido TKR11 Julio 2024.pdf"; Equipo = "Tacker 11"; Fecha = $null; Anio = "2024" }
    @{ Local = "Medición de Ruido\Tacker 07\TKR 7. Estudio de ruido 08-06-25.pdf"; Equipo = "Tacker 07"; Fecha = "2025-06-08" }
    @{ Local = "Medición de Ruido\Tacker 11\Medición 2025\TKR 11. Estudio de ruido.pdf"; Equipo = "Tacker 11"; Fecha = $null; Anio = "2025" }
    @{ Local = "Medición de Ruido\Tacker 05\Estudio de ruido TKR 05- 13-04-2026.pdf"; Equipo = "Tacker 05"; Fecha = "2026-04-13" }
    @{ Local = "Medición de Ruido\Tacker 05\POSGI001-A6-2 Estudio de Ruídos- TKR 05- Ce 1273- 13-04-26.pdf"; Equipo = "Tacker 05"; Fecha = "2026-04-13" }
    @{ Local = "Medición de Ruido\Tacker 07\POSGI001-A6-2 Estudio de Ruídos TKR 7- 09.11.25.pdf"; Equipo = "Tacker 07"; Fecha = "2025-11-09" }
    @{ Local = "Medición de Ruido\Mase 02\Estudio de ruidos MASE 02- 11-11-25.pdf"; Equipo = "Mase 02"; Fecha = "2025-11-11" }
    @{ Local = "Medición de Ruido\Mase 02\Estudio iluminación MASE 02- 11-11-25.pdf"; Equipo = "Mase 02"; Fecha = "2025-11-11"; Advertencia = "nombre dice 'iluminación', carpeta es de ruido" }
    @{ Local = "Medición de Ruido\Mase 01\MASE 01. ESTUDIO DE RUIDO 01-08-25.pdf"; Equipo = "Mase 01"; Fecha = "2025-08-01" }
    @{ Local = "Medición de Ruido\Tacker 10\Estudio de ruido TKR 10- 25-02-26.pdf"; Equipo = "Tacker 10"; Fecha = "2026-02-25" }
    @{ Local = "Medición de Ruido\Tacker 01\Estudio de ruido TKR 01- 13-06-2026.pdf"; Equipo = "Tacker 01"; Fecha = "2026-06-13" }
    @{ Local = "Medición de Ruido\Tacker 10\Estudio de ruido TKR 10- 06-07-2026.pdf"; Equipo = "Tacker 10"; Fecha = "2026-07-06" }
    @{ Local = "Medición de Ruido\Tacker 08\Estudio de ruidos TKR 08- 21-07-26.pdf"; Equipo = "Tacker 08"; Fecha = "2026-07-21" }
    @{ Local = "Medición de Ruido\Tacker 07\ESTUDIO DE RUIDOS TKR 07 LAJE-11 23-7-26.pdf"; Equipo = "Tacker 07"; Fecha = "2026-07-23" }
    @{ Local = "Medición de Ruido\Mase 01\ESTUDIO DE RUIDO MASE 01 8-9-26.pdf"; Equipo = "Mase 01"; Fecha = "2026-09-08" }
    @{ Local = "Medición de Ruido\Tacker 11\TKR 11. Estudio de ruido 26-05-26.pdf"; Equipo = "Tacker 11"; Fecha = "2026-05-26" }
)

foreach ($m in $Mapeo) {
    $m.Tipo = if ($m.Local.StartsWith("Mediciones de luz")) { "Iluminación" } else { "Ruido" }
    $m.CarpetaTipo = if ($m.Tipo -eq "Iluminación") { "Mediciones de luz" } else { "Medición de Ruido" }
    if (-not $m.ContainsKey("Anio") -or -not $m.Anio) {
        $m.AnioCarpeta = if ($m.Fecha) { $m.Fecha.Substring(0, 4) } else { "Sin fecha" }
    } else {
        $m.AnioCarpeta = $m.Anio
    }
}

# ---------------------------------------------------------------------------
# Diagnostico: que hay AHORA en la biblioteca, bajo la raiz de mediciones
# ---------------------------------------------------------------------------

function Mostrar-Diagnostico {
    Write-Host ""
    Write-Host "  Diagnostico: contenido actual de la biblioteca" -ForegroundColor White
    $filtro = "startswith(FileRef,'$RaizRelativa')"
    $uri = "$ApiSitio/web/lists(guid'$LibraryId')/items" +
           "?`$select=FileLeafRef,FileRef,FSObjType,MedEquipo,MedTipo,MedFechaMedicion,MedCliente,Created" +
           "&`$filter=$filtro&`$orderby=Created desc&`$top=2000"
    try {
        $r = Invoke-SP -Uri $uri
        $items = @($r.value)
        $archivos = $items | Where-Object { $_.FSObjType -eq 0 }
        $carpetas = $items | Where-Object { $_.FSObjType -eq 1 }
        Write-Host "  Carpetas bajo la raíz: $($carpetas.Count)" -ForegroundColor Gray
        Write-Host "  Archivos bajo la raíz: $($archivos.Count)" -ForegroundColor Gray
        if ($archivos.Count -gt 0) {
            Write-Host ""
            Write-Host "  Los 10 más recientes:" -ForegroundColor Gray
            $archivos | Select-Object -First 10 | ForEach-Object {
                $equipo = if ($_.MedEquipo -is [string]) { $_.MedEquipo } else { $_.MedEquipo.Value }
                "    $($_.Created)  $($_.FileLeafRef)  [equipo=$equipo]"
            }
        } else {
            Write-Host "  No hay NINGÚN archivo bajo '$RaizRelativa' todavía." -ForegroundColor Yellow
            Write-Host "  Esto explica «no se ven los cambios»: si algo se subió, cayó en otra ruta" -ForegroundColor Yellow
            Write-Host "  (verificar carpetaTipo/carpetaEquipo que mandó el flow, o la biblioteca)." -ForegroundColor Yellow
        }
        return $archivos
    } catch {
        Write-Host "  No se pudo consultar: $(Get-ErrorSP $_)" -ForegroundColor Red
        return @()
    }
}

# ---------------------------------------------------------------------------
# Asegurar carpeta (crea toda la ruta intermedia si falta)
# ---------------------------------------------------------------------------

function Asegurar-Carpeta {
    param([string] $RutaServidor)
    $enc = [Uri]::EscapeDataString($RutaServidor)
    try {
        Invoke-SP -Uri "$ApiSitio/web/GetFolderByServerRelativeUrl('$enc')?`$select=Exists" | Out-Null
        return
    } catch { }
    $body = @{ ServerRelativeUrl = $RutaServidor } | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    Invoke-SP -Method POST -Uri "$ApiSitio/web/folders" -BodyBytes $bytes `
        -ExtraHeaders @{ "Content-Type" = "application/json;odata=nometadata;charset=utf-8" } | Out-Null
}

# ---------------------------------------------------------------------------
# Subir un archivo y cargar sus columnas
# ---------------------------------------------------------------------------

function Subir-Documento {
    param($Item)

    $rutaLocal = Join-Path $RaizLocal $Item.Local
    if (-not (Test-Path -LiteralPath $rutaLocal)) {
        return [pscustomobject]@{ Archivo = $Item.Local; Estado = "NO ENCONTRADO"; Detalle = $rutaLocal }
    }

    $nombreArchivo = Split-Path $rutaLocal -Leaf
    $rutaCarpeta = "$RaizRelativa/$($Item.CarpetaTipo)/$($Item.Equipo)/$($Item.AnioCarpeta)"

    if ($PSCmdlet.ShouldProcess("$rutaCarpeta/$nombreArchivo", "Subir y clasificar")) {
        Asegurar-Carpeta -RutaServidor $rutaCarpeta

        $bytes = [IO.File]::ReadAllBytes($rutaLocal)
        $encCarpeta = [Uri]::EscapeDataString($rutaCarpeta)
        $encNombre = [Uri]::EscapeDataString($nombreArchivo).Replace("'", "''")
        $uriSubida = "$ApiSitio/web/GetFolderByServerRelativeUrl('$encCarpeta')/Files/add(url='$encNombre',overwrite=true)"

        try {
            $resp = Invoke-SP -Method POST -Uri $uriSubida -BodyBytes $bytes `
                -ExtraHeaders @{ "Content-Type" = "application/octet-stream" }
        } catch {
            return [pscustomobject]@{ Archivo = $Item.Local; Estado = "FALLÓ LA SUBIDA"; Detalle = (Get-ErrorSP $_) }
        }

        try {
            $li = Invoke-SP -Uri "$ApiSitio/web/GetFileByServerRelativeUrl('$encCarpeta/$encNombre')/ListItemAllFields?`$select=Id"
            $idItem = $li.Id

            $props = [ordered]@{
                MedEquipo = $Item.Equipo
                MedTipo = $Item.Tipo
                MedCliente = ""
            }
            if ($Item.Fecha) { $props.MedFechaMedicion = "$($Item.Fecha)T12:00:00Z" }

            $bodyProps = ConvertTo-JsonUtf8Bytes $props
            Invoke-SP -Method POST -Uri "$ApiSitio/web/lists(guid'$LibraryId')/items($idItem)" -BodyBytes $bodyProps `
                -ExtraHeaders @{
                    "Content-Type" = "application/json;odata=nometadata;charset=utf-8"
                    "X-HTTP-Method" = "MERGE"
                    "IF-MATCH" = "*"
                } | Out-Null
        } catch {
            return [pscustomobject]@{ Archivo = $Item.Local; Estado = "SUBIÓ, PERO NO SE PUDIERON CARGAR LAS COLUMNAS"; Detalle = (Get-ErrorSP $_) }
        }

        $estado = if ($Item.Fecha) { "OK" } else { "OK (sin fecha en el nombre)" }
        return [pscustomobject]@{ Archivo = $Item.Local; Estado = $estado; Detalle = "$rutaCarpeta/$nombreArchivo" }
    }
    return [pscustomobject]@{ Archivo = $Item.Local; Estado = "SIMULADO (-WhatIf)"; Detalle = "$rutaCarpeta/$nombreArchivo" }
}

# ---------------------------------------------------------------------------
# Programa
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Carga del historico de mediciones a SharePoint" -ForegroundColor White
Write-Host "  Archivos a procesar: $($Mapeo.Count)"
Write-Host ""

$script:Token = Get-Token

try {
    $web = Invoke-SP -Uri "$ApiSitio/web?`$select=Title"
    Write-Host "  Conectado a: $($web.Title)" -ForegroundColor Green
} catch {
    Write-Host "  No se pudo conectar: $(Get-ErrorSP $_)" -ForegroundColor Red
    exit 1
}

$existentes = Mostrar-Diagnostico

if ($SoloDiagnostico) { exit 0 }

$existentesPorNombre = @{}
foreach ($e in $existentes) { $existentesPorNombre[$e.FileLeafRef] = $true }

Write-Host ""
Write-Host "  Subiendo..." -ForegroundColor White
$resultados = @()
$i = 0
foreach ($item in $Mapeo) {
    $i++
    $nombreArchivo = Split-Path $item.Local -Leaf
    Write-Host "  [$i/$($Mapeo.Count)] $nombreArchivo" -NoNewline

    if ($existentesPorNombre.ContainsKey($nombreArchivo) -and -not $WhatIfPreference) {
        Write-Host "  = ya existe, se sobrescribe con los datos actuales" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }

    $r = Subir-Documento -Item $item
    $r | Add-Member -NotePropertyName Advertencia -NotePropertyValue $item.Advertencia -Force
    $resultados += $r

    $color = switch -Wildcard ($r.Estado) {
        "OK*" { "Green" }
        "SIMULADO*" { "Cyan" }
        "NO ENCONTRADO" { "Red" }
        default { "Red" }
    }
    Write-Host "      -> $($r.Estado)" -ForegroundColor $color
    if ($item.Advertencia) { Write-Host "      !  $($item.Advertencia)" -ForegroundColor DarkYellow }
}

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  ==================== RESUMEN ====================" -ForegroundColor White
$ok = @($resultados | Where-Object { $_.Estado -like "OK*" })
$sinFecha = @($ok | Where-Object { $_.Estado -like "*sin fecha*" })
$fallidos = @($resultados | Where-Object { $_.Estado -notlike "OK*" -and $_.Estado -notlike "SIMULADO*" })
$adverts = @($resultados | Where-Object { $_.Advertencia })

Write-Host "  Subidos correctamente: $($ok.Count) / $($Mapeo.Count)" -ForegroundColor Green
Write-Host "  De esos, sin fecha detectada en el nombre: $($sinFecha.Count)" -ForegroundColor Yellow
Write-Host "  Fallidos: $($fallidos.Count)" -ForegroundColor $(if ($fallidos.Count -gt 0) { "Red" } else { "Green" })

if ($sinFecha.Count -gt 0) {
    Write-Host ""
    Write-Host "  Sin fecha detectada (quedaron en carpeta 'Sin fecha' o la del año local," -ForegroundColor Yellow
    Write-Host "  columna Fecha de medición vacía — revisar y completar a mano):" -ForegroundColor Yellow
    $sinFecha | ForEach-Object { Write-Host "    - $($_.Archivo)" }
}
if ($adverts.Count -gt 0) {
    Write-Host ""
    Write-Host "  Nombre y carpeta no coinciden en tipo (se subió con el tipo de la carpeta):" -ForegroundColor DarkYellow
    $adverts | ForEach-Object { Write-Host "    - $($_.Archivo)  ($($_.Advertencia))" }
}
if ($fallidos.Count -gt 0) {
    Write-Host ""
    Write-Host "  Fallidos:" -ForegroundColor Red
    $fallidos | ForEach-Object { Write-Host "    - $($_.Archivo): $($_.Estado) — $($_.Detalle)" }
}

Write-Host ""
exit $(if ($fallidos.Count -gt 0) { 1 } else { 0 })
