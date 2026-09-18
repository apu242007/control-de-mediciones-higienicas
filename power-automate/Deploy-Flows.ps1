[CmdletBinding()]
param(
    [string] $EnvironmentId = "Default-2003cd32-a447-4e58-b7f9-ada4dc293241",
    [string] $SiteUrl = "https://tackersrl505.sharepoint.com/sites/QHSE",
    [string] $LibraryId = "3bcd9efb-57ca-4acf-b841-2e2557cc09d5",
    [string] $ConfigListId = "6f55f471-ce53-4610-8f10-025d2b69d4d1",
    [string] $Recipient = "jcastro@tackertools.com",
    [string] $AppKey = "",
    [ValidateSet("Day", "Minute", "Manual")] [string] $AlertFrequency = "Day"
)

$ErrorActionPreference = "Stop"
$FlowApi = "https://api.flow.microsoft.com"
$PowerAppsApi = "https://southamerica.api.powerapps.com"
$ApiVersion = "2016-11-01"

function Get-FlowToken {
    $raw = az account get-access-token --resource "https://service.flow.microsoft.com/" --output json
    if ($LASTEXITCODE -ne 0) { throw "No se pudo obtener un token de Power Automate con Azure CLI." }
    return ($raw | ConvertFrom-Json).accessToken
}

function Invoke-FlowApi {
    param(
        [ValidateSet("GET", "POST", "PATCH", "PUT")] [string] $Method,
        [string] $Uri,
        $Body
    )
    $headers = @{ Authorization = "Bearer $script:FlowToken" }
    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
    $json = $Body | ConvertTo-Json -Depth 100 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers `
        -ContentType "application/json; charset=utf-8" -Body $bytes
}

function New-ConnectorAction {
    param(
        [string] $ApiId,
        [string] $ConnectionName,
        [string] $OperationId,
        [hashtable] $Parameters,
        [hashtable] $RunAfter = @{}
    )
    return [ordered]@{
        type = "OpenApiConnection"
        inputs = [ordered]@{
            host = [ordered]@{
                apiId = "/providers/Microsoft.PowerApps/apis/$ApiId"
                connectionName = $ConnectionName
                operationId = $OperationId
            }
            parameters = $Parameters
            authentication = "@parameters('$" + "authentication')"
        }
        runAfter = $RunAfter
    }
}

function New-ResponseAction {
    param([int] $StatusCode, $Body, [hashtable] $RunAfter = @{})
    return [ordered]@{
        type = "Response"
        kind = "Http"
        inputs = [ordered]@{
            statusCode = $StatusCode
            headers = @{ "Content-Type" = "application/json" }
            body = $Body
        }
        runAfter = $RunAfter
    }
}

function New-TerminateAction {
    param([string] $After)
    return [ordered]@{
        type = "Terminate"
        inputs = @{ runStatus = "Failed" }
        runAfter = @{ $After = @("Succeeded") }
    }
}

function ConvertTo-ExprLiteral {
    param([string] $Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

# Valor de usuario -> seguro para incrustar en CAML dentro de un JSON armado a mano.
function Get-CamlSafe {
    param([string] $Expr)
    return "replace(replace(replace(replace(replace(replace($Expr, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '''', '&apos;'), '""', ''), '\', '')"
}

# RenderListDataAsStream devuelve las fechas en formato local (dd/MM/yyyy); el cliente espera ISO.
function Get-FechaIsoExpr {
    param([string] $Campo)
    $s = "string(coalesce(item()?['$Campo'], ''))"
    return "if(equals(length($s), 10), concat(substring($s, 6, 4), '-', substring($s, 3, 2), '-', substring($s, 0, 2), 'T12:00:00Z'), '')"
}

function New-Definition {
    param($Triggers, $Actions)
    return [ordered]@{
        '$schema' = "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"
        contentVersion = "1.0.0.0"
        parameters = [ordered]@{
            '$authentication' = @{ defaultValue = @{}; type = "SecureObject" }
            '$connections' = @{ defaultValue = @{}; type = "Object" }
        }
        triggers = $Triggers
        actions = $Actions
        outputs = @{}
    }
}

function New-Flow {
    param([string] $DisplayName, $Definition, $ConnectionReferences)
    $existing = (Invoke-FlowApi -Method GET -Uri "$FlowApi/providers/Microsoft.ProcessSimple/environments/$EnvironmentId/flows?api-version=$ApiVersion").value |
        Where-Object { $_.properties.displayName -eq $DisplayName }
    if (@($existing).Count -gt 1) {
        throw "Hay más de un flow llamado '$DisplayName'. No se puede elegir uno de forma segura."
    }
    $payload = [ordered]@{
        properties = [ordered]@{
            displayName = $DisplayName
            definition = $Definition
            connectionReferences = $ConnectionReferences
            state = "Started"
        }
    }
    if ($existing) {
        $id = $existing[0].name
        return Invoke-FlowApi -Method PATCH -Uri "$FlowApi/providers/Microsoft.ProcessSimple/environments/$EnvironmentId/flows/${id}?api-version=$ApiVersion" -Body $payload
    }
    return Invoke-FlowApi -Method POST -Uri "$FlowApi/providers/Microsoft.ProcessSimple/environments/$EnvironmentId/flows?api-version=$ApiVersion" -Body $payload
}

if (-not $AppKey) {
    $random = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($random)
    $AppKey = [Convert]::ToBase64String($random).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$script:FlowToken = Get-FlowToken
$connectionsUri = "$PowerAppsApi/providers/Microsoft.PowerApps/connections?api-version=$ApiVersion&`$filter=environment%20eq%20'$EnvironmentId'"
$connections = (Invoke-FlowApi -Method GET -Uri $connectionsUri).value
$sp = $connections | Where-Object {
    $_.properties.apiId -eq "/providers/Microsoft.PowerApps/apis/shared_sharepointonline" -and
    $_.properties.statuses[0].status -eq "Connected"
} | Select-Object -First 1
$mail = $connections | Where-Object {
    $_.properties.apiId -eq "/providers/Microsoft.PowerApps/apis/shared_office365" -and
    $_.properties.statuses[0].status -eq "Connected"
} | Select-Object -First 1
if (-not $sp) { throw "No hay una conexión SharePoint Online en estado Connected en $EnvironmentId." }
if (-not $mail) { throw "No hay una conexión Office 365 Outlook en estado Connected en $EnvironmentId." }

$spRef = [ordered]@{
    connectionName = $sp.name
    source = "Embedded"
    id = "/providers/Microsoft.PowerApps/apis/shared_sharepointonline"
    displayName = "SharePoint"
    tier = "NotSpecified"
    apiName = "sharepointonline"
}
$mailRef = [ordered]@{
    connectionName = $mail.name
    source = "Embedded"
    id = "/providers/Microsoft.PowerApps/apis/shared_office365"
    displayName = "Office 365 Outlook"
    tier = "Standard"
    apiName = "office365"
}

$apiActions = [ordered]@{}
$apiActions.Verificar_clave = [ordered]@{
    type = "If"
    expression = "@equals(triggerOutputs()?['headers']?['x-app-key'], '$AppKey')"
    actions = @{}
    else = @{ actions = [ordered]@{
        Respuesta_401_Clave = New-ResponseAction 401 @{ error = "Solicitud no autorizada." }
        Terminar_Clave = New-TerminateAction "Respuesta_401_Clave"
    } }
    runAfter = @{}
}
$apiActions.Init_varAccion = [ordered]@{
    type = "InitializeVariable"
    inputs = @{ variables = @(@{ name = "varAccion"; type = "String"; value = "@toLower(coalesce(triggerBody()?['accion'], ''))" }) }
    runAfter = @{ Verificar_clave = @("Succeeded") }
}
$apiActions.Init_varClavePin = [ordered]@{
    type = "InitializeVariable"
    inputs = @{ variables = @(@{ name = "varClavePin"; type = "String"; value = "@if(equals(variables('varAccion'), 'subir'), 'PIN_CARGA', 'PIN_CONSULTA')" }) }
    runAfter = @{ Init_varAccion = @("Succeeded") }
}
$apiActions.Init_varPinOk = [ordered]@{
    type = "InitializeVariable"
    inputs = @{ variables = @(@{ name = "varPinOk"; type = "Boolean"; value = $false }) }
    runAfter = @{ Init_varClavePin = @("Succeeded") }
}
$apiActions.Init_varFallidos = [ordered]@{
    type = "InitializeVariable"
    inputs = @{ variables = @(@{ name = "varFallidos"; type = "Integer"; value = 0 }) }
    runAfter = @{ Init_varPinOk = @("Succeeded") }
}
$apiActions.Obtener_config = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "GetItems" ([ordered]@{
    dataset = $SiteUrl
    table = $ConfigListId
    '$filter' = "@concat('Title eq ''', variables('varClavePin'), '''')"
    '$top' = 1
}) @{ Init_varFallidos = @("Succeeded") }
$apiActions.Verificar_bloqueo = [ordered]@{
    type = "If"
    expression = "@greater(ticks(coalesce(first(body('Obtener_config')?['value'])?['CfgBloqueadoHasta'], '2000-01-01T00:00:00Z')), ticks(utcNow()))"
    actions = [ordered]@{
        Respuesta_429 = New-ResponseAction 429 @{ error = "Demasiados intentos fallidos. Volvé a probar en unos minutos." }
        Terminar_Bloqueo = New-TerminateAction "Respuesta_429"
    }
    else = @{ actions = @{} }
    runAfter = @{ Obtener_config = @("Succeeded") }
}

$sumarParams = [ordered]@{
    dataset = $SiteUrl
    table = $ConfigListId
    id = "@first(body('Obtener_config')?['value'])?['ID']"
    'item/Title' = "@variables('varClavePin')"
    'item/CfgValor' = "@first(body('Obtener_config')?['value'])?['CfgValor']"
    'item/CfgFallidos' = "@add(int(coalesce(first(body('Obtener_config')?['value'])?['CfgFallidos'], 0)), 1)"
    'item/CfgBloqueadoHasta' = "@if(greaterOrEquals(add(int(coalesce(first(body('Obtener_config')?['value'])?['CfgFallidos'], 0)), 1), 5), addMinutes(utcNow(), 15), null)"
}
$resetParams = [ordered]@{
    dataset = $SiteUrl
    table = $ConfigListId
    id = "@first(body('Obtener_config')?['value'])?['ID']"
    'item/Title' = "@variables('varClavePin')"
    'item/CfgValor' = "@first(body('Obtener_config')?['value'])?['CfgValor']"
    'item/CfgFallidos' = 0
    'item/CfgBloqueadoHasta' = $null
}
$apiActions.Verificar_pin = [ordered]@{
    type = "If"
    expression = "@equals(first(body('Obtener_config')?['value'])?['CfgValor'], coalesce(triggerBody()?['pin'], ''))"
    actions = [ordered]@{
        Resetear_fallidos = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "PatchItem" $resetParams
    }
    else = @{ actions = [ordered]@{
        Sumar_fallido = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "PatchItem" $sumarParams
        Respuesta_401_Pin = New-ResponseAction 401 @{ error = "PIN incorrecto." } @{ Sumar_fallido = @("Succeeded") }
        Terminar_Pin = New-TerminateAction "Respuesta_401_Pin"
    } }
    runAfter = @{ Verificar_bloqueo = @("Succeeded") }
}

$subir = [ordered]@{}
$subir.Crear_carpeta = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "CreateNewFolder" ([ordered]@{
    dataset = $SiteUrl
    table = $LibraryId
    'parameters/path' = "@concat('16 - Mediciones Higiénicas LUZ y RUIDO/', triggerBody()?['carpetaTipo'], '/', triggerBody()?['carpetaEquipo'], '/', triggerBody()?['carpetaAnio'])"
})
$subir.Crear_archivo = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "CreateFile" ([ordered]@{
    dataset = $SiteUrl
    folderPath = "@concat('/Documentos QHSE/16 - Mediciones Higiénicas LUZ y RUIDO/', triggerBody()?['carpetaTipo'], '/', triggerBody()?['carpetaEquipo'], '/', triggerBody()?['carpetaAnio'])"
    name = "@triggerBody()?['nombreArchivo']"
    body = "@base64ToBinary(triggerBody()?['contenidoBase64'])"
}) @{ Crear_carpeta = @("Succeeded", "Failed", "Skipped") }
$subir.Crear_archivo.runtimeConfiguration = @{ contentTransfer = @{ transferMode = "Chunked" } }
$subir.Actualizar_propiedades = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "PatchFileItem" ([ordered]@{
    dataset = $SiteUrl
    table = $LibraryId
    id = "@outputs('Crear_archivo')?['body/ItemId']"
    'item/MedEquipo/Value' = "@triggerBody()?['equipo']"
    'item/MedCliente' = "@triggerBody()?['cliente']"
    'item/MedTipo/Value' = "@triggerBody()?['tipoMedicion']"
    'item/MedFechaMedicion' = "@triggerBody()?['fechaMedicion']"
    'item/MedFechaVencimiento' = "@triggerBody()?['fechaVencimiento']"
    'item/MedVigenciaMeses' = "@if(equals(triggerBody()?['vigenciaMeses'], null), null, int(triggerBody()?['vigenciaMeses']))"
}) @{ Crear_archivo = @("Succeeded") }
$subir.Respuesta_subir = New-ResponseAction 200 ([ordered]@{
    ok = $true
    nombreArchivo = "@outputs('Crear_archivo')?['body/Name']"
    rutaRelativa = "@outputs('Crear_archivo')?['body/Path']"
    urlSharePoint = "@outputs('Crear_archivo')?['body/{Link}']"
}) @{ Actualizar_propiedades = @("Succeeded") }

# El endpoint /items devuelve vacío en esta biblioteca (quirk de SharePoint, con filtro o sin él),
# así que se consulta con CAML por RenderListDataAsStream. Prefijo ASCII a propósito: evita el acento de "Higiénicas".
$camlRaiz = "<BeginsWith><FieldRef Name='FileRef'/><Value Type='Text'>/sites/QHSE/Documentos QHSE/16 - Mediciones Hig</Value></BeginsWith>"
$camlSiempreVerdadero = "<Neq><FieldRef Name='ID'/><Value Type='Counter'>0</Value></Neq>"

function Get-CamlCondicion {
    param([string] $Clave, [string] $Campo, [string] $TipoValor, [string] $Operador, [switch] $SoloFecha)
    $valor = "coalesce(triggerBody()?['$Clave'], '')"
    $atributoFecha = ""
    if ($SoloFecha) {
        $valor = "substring(concat($valor, '0000000000'), 0, 10)"
        $atributoFecha = " IncludeTimeValue=''FALSE''"
    }
    $real = "concat('<$Operador><FieldRef Name=''$Campo''/><Value Type=''$TipoValor''$atributoFecha>', $(Get-CamlSafe $valor), '</Value></$Operador>')"
    return "if(empty(coalesce(triggerBody()?['$Clave'], '')), $(ConvertTo-ExprLiteral $camlSiempreVerdadero), $real)"
}

$camlCampos = "<FieldRef Name='ID'/><FieldRef Name='FileLeafRef'/><FieldRef Name='FileRef'/><FieldRef Name='MedEquipo'/><FieldRef Name='MedCliente'/><FieldRef Name='MedTipo'/><FieldRef Name='MedFechaMedicion'/><FieldRef Name='MedFechaVencimiento'/><FieldRef Name='MedVigenciaMeses'/>"
$listarPartes = @(
    (ConvertTo-ExprLiteral ('{"parameters":{"RenderOptions":2,"ViewXml":"<View Scope=''RecursiveAll''><Query><Where><And><And><And><And><And><And>' + $camlRaiz + "<Eq><FieldRef Name='FSObjType'/><Value Type='Integer'>0</Value></Eq></And>")),
    (Get-CamlCondicion "tipoMedicion" "MedTipo" "Text" "Eq"), (ConvertTo-ExprLiteral "</And>"),
    (Get-CamlCondicion "equipo" "MedEquipo" "Text" "Eq"), (ConvertTo-ExprLiteral "</And>"),
    (Get-CamlCondicion "cliente" "MedCliente" "Text" "Eq"), (ConvertTo-ExprLiteral "</And>"),
    (Get-CamlCondicion "desde" "MedFechaMedicion" "DateTime" "Geq" -SoloFecha), (ConvertTo-ExprLiteral "</And>"),
    (Get-CamlCondicion "hasta" "MedFechaMedicion" "DateTime" "Leq" -SoloFecha), (ConvertTo-ExprLiteral "</And>"),
    (ConvertTo-ExprLiteral ("</Where></Query><ViewFields>$camlCampos</ViewFields><RowLimit>2000</RowLimit></View>" + '"}}'))
)

$listar = [ordered]@{}
$listar.Consultar_archivos = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "HttpRequest" ([ordered]@{
    dataset = $SiteUrl
    'parameters/method' = "POST"
    'parameters/uri' = "_api/web/lists(guid'$LibraryId')/RenderListDataAsStream"
    'parameters/headers' = @{ Accept = "application/json;odata=nometadata"; "Content-Type" = "application/json;odata=nometadata" }
    'parameters/body' = "@concat($($listarPartes -join ', '))"
})
$listar.Seleccionar_filas = [ordered]@{
    type = "Select"
    inputs = [ordered]@{
        from = "@coalesce(body('Consultar_archivos')?['Row'], json('[]'))"
        select = [ordered]@{
            id = "@int(item()?['ID'])"
            nombre = "@item()?['FileLeafRef']"
            rutaRelativa = "@item()?['FileRef']"
            equipo = "@string(coalesce(item()?['MedEquipo'], ''))"
            cliente = "@string(coalesce(item()?['MedCliente'], ''))"
            tipoMedicion = "@string(coalesce(item()?['MedTipo'], ''))"
            fechaMedicion = "@$(Get-FechaIsoExpr 'MedFechaMedicion')"
            fechaVencimiento = "@$(Get-FechaIsoExpr 'MedFechaVencimiento')"
            urlSharePoint = "@concat('https://tackersrl505.sharepoint.com', item()?['FileRef'])"
        }
    }
    runAfter = @{ Consultar_archivos = @("Succeeded") }
}
$listar.Respuesta_listar = New-ResponseAction 200 ([ordered]@{
    ok = $true
    items = "@body('Seleccionar_filas')"
    truncado = "@greaterOrEquals(length(body('Seleccionar_filas')), 2000)"
}) @{ Seleccionar_filas = @("Succeeded") }

$descargar = [ordered]@{}
$descargar.Obtener_contenido = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "GetFileContentByPath" ([ordered]@{
    dataset = $SiteUrl
    path = "@replace(triggerBody()?['rutaRelativa'], '/sites/QHSE', '')"
    inferContentType = $false
})
$descargar.Respuesta_descargar = New-ResponseAction 200 ([ordered]@{
    ok = $true
    contenidoBase64 = "@base64(body('Obtener_contenido'))"
}) @{ Obtener_contenido = @("Succeeded") }

$apiActions.Conmutador_accion = [ordered]@{
    type = "Switch"
    expression = "@variables('varAccion')"
    cases = [ordered]@{
        subir = @{ case = "subir"; actions = $subir }
        listar = @{ case = "listar"; actions = $listar }
        descargar = @{ case = "descargar"; actions = $descargar }
    }
    default = @{ actions = [ordered]@{
        Respuesta_accion_invalida = New-ResponseAction 400 @{ error = "Acción no reconocida." }
    } }
    runAfter = @{ Verificar_pin = @("Succeeded") }
}

$apiTriggers = [ordered]@{
    manual = [ordered]@{
        type = "Request"
        kind = "Http"
        inputs = [ordered]@{
            schema = @{ type = "object"; properties = @{} }
            method = "POST"
            triggerAuthenticationType = "All"
        }
    }
}
$apiDefinition = New-Definition $apiTriggers $apiActions
$apiFlow = New-Flow "MED-API" $apiDefinition @{ shared_sharepointonline = $spRef }

$alertActions = [ordered]@{}
$alertActions.Init_varHoy = [ordered]@{
    type = "InitializeVariable"
    inputs = @{ variables = @(@{ name = "varHoy"; type = "String"; value = "@formatDateTime(convertTimeZone(utcNow(), 'UTC', 'Argentina Standard Time'), 'yyyy-MM-dd')" }) }
    runAfter = @{}
}
$alertActions.Init_varVistos = [ordered]@{
    type = "InitializeVariable"
    inputs = @{ variables = @(@{ name = "varVistos"; type = "String"; value = "" }) }
    runAfter = @{ Init_varHoy = @("Succeeded") }
}
# Se traen TODOS los documentos con vencimiento, del más nuevo al más viejo: solo avisa el último de cada Equipo+Tipo.
$alertaCaml = '{"parameters":{"RenderOptions":2,"ViewXml":"<View Scope=''RecursiveAll''><Query><Where><And>' + $camlRaiz + "<IsNotNull><FieldRef Name='MedFechaVencimiento'/></IsNotNull></And></Where><OrderBy><FieldRef Name='MedFechaMedicion' Ascending='FALSE'/><FieldRef Name='ID' Ascending='FALSE'/></OrderBy></Query><ViewFields><FieldRef Name='ID'/><FieldRef Name='FileLeafRef'/><FieldRef Name='FileRef'/><FieldRef Name='MedEquipo'/><FieldRef Name='MedCliente'/><FieldRef Name='MedTipo'/><FieldRef Name='MedFechaMedicion'/><FieldRef Name='MedFechaVencimiento'/><FieldRef Name='MedVigenciaMeses'/><FieldRef Name='MedAlertaEnviada'/></ViewFields><RowLimit>2000</RowLimit></View>" + '"}}'
$alertActions.Consultar_vencimientos = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "HttpRequest" ([ordered]@{
    dataset = $SiteUrl
    'parameters/method' = "POST"
    'parameters/uri' = "_api/web/lists(guid'$LibraryId')/RenderListDataAsStream"
    'parameters/headers' = @{ Accept = "application/json;odata=nometadata"; "Content-Type" = "application/json;odata=nometadata" }
    'parameters/body' = "@$(ConvertTo-ExprLiteral $alertaCaml)"
}) @{ Init_varVistos = @("Succeeded") }
$alertActions.Normalizar_filas = [ordered]@{
    type = "Select"
    inputs = [ordered]@{
        from = "@coalesce(body('Consultar_vencimientos')?['Row'], json('[]'))"
        select = [ordered]@{
            Id = "@int(item()?['ID'])"
            FileLeafRef = "@item()?['FileLeafRef']"
            FileRef = "@item()?['FileRef']"
            MedEquipo = "@string(coalesce(item()?['MedEquipo'], ''))"
            MedCliente = "@string(coalesce(item()?['MedCliente'], ''))"
            MedTipo = "@string(coalesce(item()?['MedTipo'], ''))"
            MedFechaMedicion = "@$(Get-FechaIsoExpr 'MedFechaMedicion')"
            MedFechaVencimiento = "@$(Get-FechaIsoExpr 'MedFechaVencimiento')"
            MedVigenciaMeses = "@string(coalesce(item()?['MedVigenciaMeses'], ''))"
            MedAlertaEnviada = "@string(coalesce(item()?['MedAlertaEnviada'], ''))"
        }
    }
    runAfter = @{ Consultar_vencimientos = @("Succeeded") }
}
$hito = "if(less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())), concat('vencido-', formatDateTime(convertTimeZone(utcNow(),'UTC','Argentina Standard Time'), 'yyyy'), '-', string(div(sub(dayOfYear(convertTimeZone(utcNow(),'UTC','Argentina Standard Time')), 1), 7))),if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 7))), 'd7', if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 15))), 'd15', 'd30')))"
$venc = "item()?['MedFechaVencimiento']"
$estaVencida = "less(ticks($venc), ticks(utcNow()))"
$diasAbs = "div(if($estaVencida, sub(ticks(utcNow()), ticks($venc)), sub(ticks($venc), ticks(utcNow()))), 864000000000)"
$fechaVenc = "formatDateTime($venc, 'dd/MM/yyyy')"
$fechaMed = "if(empty(item()?['MedFechaMedicion']), 's/d', formatDateTime(item()?['MedFechaMedicion'], 'dd/MM/yyyy'))"
$clienteTxt = "if(empty(item()?['MedCliente']), 's/d', item()?['MedCliente'])"
$vigenciaTxt = "if(empty(item()?['MedVigenciaMeses']), 's/d', concat(item()?['MedVigenciaMeses'], ' meses'))"
$urlDoc = "concat('https://tackersrl505.sharepoint.com', item()?['FileRef'])"
$urlApp = "https://apu242007.github.io/control-de-mediciones-higienicas/"
$fila = { param($etiqueta, $expr, $fondo) "<tr><td style=""padding:11px 16px;background:$fondo;border-bottom:1px solid #e4e7ec;width:38%;color:#667085;font-size:13px"">$etiqueta</td><td style=""padding:11px 16px;background:$fondo;border-bottom:1px solid #e4e7ec;color:#101828;font-size:14px;font-weight:600"">@{$expr}</td></tr>" }
$mailBody = @"
<div style="background:#f2f4f7;padding:24px 12px;font-family:Segoe UI,Helvetica,Arial,sans-serif;color:#101828">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;margin:0 auto;background:#ffffff;border:1px solid #dfe3e8;border-collapse:separate">
<tr><td style="background:#0b3d6b;padding:22px 28px">
<div style="color:#a9c3dd;font-size:12px;letter-spacing:1px;text-transform:uppercase">Tacker &middot; Control de Mediciones Higiénicas</div>
<div style="color:#ffffff;font-size:21px;font-weight:600;margin-top:6px">Aviso de vencimiento de medición</div>
</td></tr>
<tr><td style="padding:24px 28px 8px 28px">
@{if($estaVencida, concat('<div style="background:#fef3f2;border:1px solid #fda29b;border-left:6px solid #b42318;padding:14px 18px"><div style="color:#b42318;font-size:12px;font-weight:700;letter-spacing:1px">MEDICIÓN VENCIDA</div><div style="color:#101828;font-size:17px;font-weight:600;margin-top:4px">Venció el ', $fechaVenc, ' (hace ', string($diasAbs), ' días)</div></div>'), concat('<div style="background:#fffaeb;border:1px solid #fedf89;border-left:6px solid #b54708;padding:14px 18px"><div style="color:#b54708;font-size:12px;font-weight:700;letter-spacing:1px">PRÓXIMA A VENCER</div><div style="color:#101828;font-size:17px;font-weight:600;margin-top:4px">Vence el ', $fechaVenc, ' (en ', string($diasAbs), ' días)</div></div>'))}
</td></tr>
<tr><td style="padding:16px 28px 4px 28px;font-size:14px;line-height:21px;color:#344054">
Esta es la medición más reciente registrada para este equipo y tipo de estudio. Para mantener el cumplimiento, hay que realizar una nueva medición.
</td></tr>
<tr><td style="padding:12px 28px 8px 28px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e4e7ec;border-collapse:collapse">
$(& $fila 'Equipo' "string(coalesce(item()?['MedEquipo'], 's/d'))" '#ffffff')
$(& $fila 'Tipo de medición' "string(coalesce(item()?['MedTipo'], 's/d'))" '#f9fafb')
$(& $fila 'Cliente / Operadora' $clienteTxt '#ffffff')
$(& $fila 'Fecha de medición' $fechaMed '#f9fafb')
$(& $fila 'Fecha de vencimiento' $fechaVenc '#ffffff')
$(& $fila 'Vigencia aplicada' $vigenciaTxt '#f9fafb')
$(& $fila 'Archivo' "item()?['FileLeafRef']" '#ffffff')
</table>
</td></tr>
<tr><td align="center" style="padding:20px 28px 8px 28px">
<a href="@{$urlDoc}" style="display:inline-block;background:#0b3d6b;color:#ffffff;text-decoration:none;font-size:15px;font-weight:600;padding:13px 28px;border-radius:6px">Abrir documento en SharePoint</a>
</td></tr>
<tr><td style="padding:20px 28px 8px 28px">
<div style="background:#f9fafb;border:1px solid #e4e7ec;padding:14px 18px;font-size:13px;line-height:20px;color:#344054">
<b style="color:#101828">Qué hacer</b><br>
1. Programar la nueva medición del equipo.<br>
2. Cargar el PDF en la <a href="$urlApp" style="color:#0b3d6b">aplicación de mediciones</a>. Al cargarlo, este aviso deja de enviarse.
</div>
</td></tr>
<tr><td style="padding:16px 28px 24px 28px;font-size:12px;line-height:18px;color:#98a2b3;border-top:1px solid #eaecf0">
Mensaje automático de Control de Mediciones Higiénicas. @{if($estaVencida, 'Se repite una vez por semana mientras la medición siga vencida.', 'Se envían recordatorios a 30, 15 y 7 días del vencimiento.')} No responder a este correo.
</td></tr>
</table>
</div>
"@
$loopActions = [ordered]@{}
$loopActions.Calcular_hito = [ordered]@{
    type = "Compose"
    inputs = "@$hito"
    runAfter = @{}
}
$loopActions.Enviar_correo = New-ConnectorAction "shared_office365" "shared_office365" "SendEmailV2" ([ordered]@{
    'emailMessage/To' = $Recipient
    'emailMessage/Subject' = "@concat(if($estaVencida, 'Medición VENCIDA', 'Medición por vencer'), ' · ', item()?['MedTipo'], ' · ', item()?['MedEquipo'], if($estaVencida, ' · venció el ', ' · vence el '), $fechaVenc)"
    'emailMessage/Body' = $mailBody
    'emailMessage/Importance' = "Normal"
}) @{ Calcular_hito = @("Succeeded") }
$loopActions.Marcar_notificado = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "PatchFileItem" ([ordered]@{
    dataset = $SiteUrl
    table = $LibraryId
    id = "@item()?['Id']"
    'item/MedAlertaEnviada' = "@outputs('Calcular_hito')"
}) @{ Enviar_correo = @("Succeeded") }
$claveGrupo = "concat('|', item()?['MedEquipo'], '~', item()?['MedTipo'], '|')"
$vencimientoCercano = "if(empty(item()?['MedFechaVencimiento']), false, lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 30))))"
$loopVerificar = [ordered]@{}
$loopVerificar.Registrar_visto = [ordered]@{
    type = "AppendToStringVariable"
    inputs = @{ name = "varVistos"; value = "@$claveGrupo" }
    runAfter = @{}
}
$loopVerificar.Evaluar_alerta = [ordered]@{
    type = "If"
    expression = "@and($vencimientoCercano, not(equals(coalesce(item()?['MedAlertaEnviada'], ''), $hito)))"
    actions = $loopActions
    else = @{ actions = @{} }
    runAfter = @{ Registrar_visto = @("Succeeded") }
}
$alertActions.Recorrer_documentos = [ordered]@{
    type = "Foreach"
    foreach = "@body('Normalizar_filas')"
    actions = [ordered]@{
        Verificar_ultimo = [ordered]@{
            type = "If"
            expression = "@not(contains(variables('varVistos'), $claveGrupo))"
            actions = $loopVerificar
            else = @{ actions = @{} }
            runAfter = @{}
        }
    }
    runAfter = @{ Normalizar_filas = @("Succeeded") }
    runtimeConfiguration = @{ concurrency = @{ repetitions = 1 } }
}
if ($AlertFrequency -eq "Manual") {
    $alertTriggers = [ordered]@{
        Periodicidad = [ordered]@{
            type = "Request"
            kind = "Http"
            inputs = [ordered]@{
                schema = @{ type = "object"; properties = @{} }
                method = "POST"
                triggerAuthenticationType = "All"
            }
        }
    }
} else {
    $alertRecurrence = [ordered]@{
        frequency = $AlertFrequency
        interval = 1
        timeZone = "Argentina Standard Time"
    }
    if ($AlertFrequency -eq "Day") {
        $alertRecurrence.schedule = @{ hours = @(8); minutes = @(0) }
    }
    $alertTriggers = [ordered]@{
        Periodicidad = [ordered]@{
            type = "Recurrence"
            recurrence = $alertRecurrence
        }
    }
}
$alertDefinition = New-Definition $alertTriggers $alertActions
$alertFlow = New-Flow "MED-Alertas" $alertDefinition @{
    shared_sharepointonline = $spRef
    shared_office365 = $mailRef
}

$callback = Invoke-FlowApi -Method POST -Uri "$FlowApi/providers/Microsoft.ProcessSimple/environments/$EnvironmentId/flows/$($apiFlow.name)/triggers/manual/listCallbackUrl?api-version=$ApiVersion" -Body @{}
$callbackUrl = if ($callback.value) { $callback.value } else { $callback.response.value }
[pscustomobject]@{
    EnvironmentId = $EnvironmentId
    ApiFlowId = $apiFlow.name
    AlertFlowId = $alertFlow.name
    UrlFlow = $callbackUrl
    AppKey = $AppKey
}
