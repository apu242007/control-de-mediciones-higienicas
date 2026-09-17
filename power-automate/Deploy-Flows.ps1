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

$listar = [ordered]@{}
$listar.Consultar_archivos = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "HttpRequest" ([ordered]@{
    dataset = $SiteUrl
    'parameters/method' = "GET"
    'parameters/uri' = "@concat('_api/web/GetList(''/sites/QHSE/Documentos QHSE'')/items', '?`$select=Id,FileLeafRef,FileRef,MedEquipo,MedCliente,MedTipo,MedFechaMedicion,MedFechaVencimiento,MedVigenciaMeses', '&`$filter=startswith(FileRef,''/sites/QHSE/Documentos QHSE/16 - Mediciones Higiénicas LUZ y RUIDO'')', if(empty(coalesce(triggerBody()?['tipoMedicion'],'')), '', concat(' and MedTipo eq ''', triggerBody()?['tipoMedicion'], '''')), if(empty(coalesce(triggerBody()?['equipo'],'')), '', concat(' and MedEquipo eq ''', triggerBody()?['equipo'], '''')), if(empty(coalesce(triggerBody()?['cliente'],'')), '', concat(' and MedCliente eq ''', triggerBody()?['cliente'], '''')), if(empty(coalesce(triggerBody()?['desde'],'')), '', concat(' and MedFechaMedicion ge datetime''', triggerBody()?['desde'], '''')), if(empty(coalesce(triggerBody()?['hasta'],'')), '', concat(' and MedFechaMedicion le datetime''', triggerBody()?['hasta'], '''')), '&`$top=2000')"
    'parameters/headers' = @{ Accept = "application/json;odata=nometadata" }
})
$listar.Seleccionar_filas = [ordered]@{
    type = "Select"
    inputs = [ordered]@{
        from = "@body('Consultar_archivos')?['value']"
        select = [ordered]@{
            id = "@item()?['Id']"
            nombre = "@item()?['FileLeafRef']"
            rutaRelativa = "@item()?['FileRef']"
            equipo = "@if(startsWith(string(item()?['MedEquipo']), '{'), json(string(item()?['MedEquipo']))?['Value'], string(coalesce(item()?['MedEquipo'], '')))"
            cliente = "@string(coalesce(item()?['MedCliente'], ''))"
            tipoMedicion = "@if(startsWith(string(item()?['MedTipo']), '{'), json(string(item()?['MedTipo']))?['Value'], string(coalesce(item()?['MedTipo'], '')))"
            fechaMedicion = "@string(coalesce(item()?['MedFechaMedicion'], ''))"
            fechaVencimiento = "@string(coalesce(item()?['MedFechaVencimiento'], ''))"
            urlSharePoint = "@concat('https://tackersrl505.sharepoint.com', item()?['FileRef'])"
        }
    }
    runAfter = @{ Consultar_archivos = @("Succeeded") }
}
$listar.Respuesta_listar = New-ResponseAction 200 ([ordered]@{
    ok = $true
    items = "@body('Seleccionar_filas')"
    truncado = "@greaterOrEquals(length(body('Consultar_archivos')?['value']), 2000)"
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
$alertActions.Consultar_vencimientos = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "HttpRequest" ([ordered]@{
    dataset = $SiteUrl
    'parameters/method' = "GET"
    'parameters/uri' = "@concat('_api/web/GetList(''/sites/QHSE/Documentos QHSE'')/items', '?`$select=Id,FileLeafRef,FileRef,MedEquipo,MedCliente,MedTipo,MedFechaMedicion,MedFechaVencimiento,MedAlertaEnviada', '&`$filter=startswith(FileRef,''/sites/QHSE/Documentos QHSE/16 - Mediciones Higiénicas LUZ y RUIDO'') and MedFechaVencimiento ne null and MedFechaVencimiento le datetime''', formatDateTime(addDays(utcNow(), 30), 'yyyy-MM-dd'), 'T23:59:59Z''', '&`$top=2000')"
    'parameters/headers' = @{ Accept = "application/json;odata=nometadata" }
}) @{ Init_varHoy = @("Succeeded") }
$hito = "if(less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())), concat('vencido-', formatDateTime(convertTimeZone(utcNow(),'UTC','Argentina Standard Time'), 'yyyy-ww')), if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 7))), 'd7', if(lessOrEquals(ticks(item()?['MedFechaVencimiento']), ticks(addDays(utcNow(), 15))), 'd15', 'd30')))"
$alertActions.Filtrar_a_notificar = [ordered]@{
    type = "Query"
    inputs = [ordered]@{
        from = "@body('Consultar_vencimientos')?['value']"
        where = "@not(equals(coalesce(item()?['MedAlertaEnviada'], ''), $hito))"
    }
    runAfter = @{ Consultar_vencimientos = @("Succeeded") }
}
$mailBody = @'
<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#14202b;max-width:640px">
@{if(less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())), concat('<div style="background:#fdecea;border-left:6px solid #b91c1c;padding:14px 16px"><b>MEDICIÓN VENCIDA</b><br>Venció el ', formatDateTime(item()?['MedFechaVencimiento'], 'dd/MM/yyyy'), '.</div>'), concat('<div style="background:#fef3c7;border-left:6px solid #d97706;padding:14px 16px"><b>PRÓXIMA A VENCER</b><br>Vence el ', formatDateTime(item()?['MedFechaVencimiento'], 'dd/MM/yyyy'), '.</div>'))}
<table cellpadding="8" cellspacing="0" style="border-collapse:collapse;width:100%;margin-top:18px">
<tr><td><b>Equipo</b></td><td>@{if(startsWith(string(item()?['MedEquipo']), '{'), json(string(item()?['MedEquipo']))?['Value'], string(coalesce(item()?['MedEquipo'], 's/d')))}</td></tr>
<tr><td><b>Tipo</b></td><td>@{if(startsWith(string(item()?['MedTipo']), '{'), json(string(item()?['MedTipo']))?['Value'], string(coalesce(item()?['MedTipo'], 's/d')))}</td></tr>
<tr><td><b>Cliente</b></td><td>@{string(coalesce(item()?['MedCliente'], 's/d'))}</td></tr>
<tr><td><b>Archivo</b></td><td>@{item()?['FileLeafRef']}</td></tr>
</table>
<p><a href="@{concat('https://tackersrl505.sharepoint.com', item()?['FileRef'])}">Abrir el documento</a></p>
</div>
'@
$loopActions = [ordered]@{}
$loopActions.Calcular_hito = [ordered]@{
    type = "Compose"
    inputs = "@$hito"
    runAfter = @{}
}
$loopActions.Enviar_correo = New-ConnectorAction "shared_office365" "shared_office365" "SendEmailV2" ([ordered]@{
    'emailMessage/To' = $Recipient
    'emailMessage/Subject' = "@concat(if(less(ticks(item()?['MedFechaVencimiento']), ticks(utcNow())), 'VENCIDA - ', 'Por vencer - '), 'Medición ', if(startsWith(string(item()?['MedTipo']), '{'), json(string(item()?['MedTipo']))?['Value'], string(coalesce(item()?['MedTipo'], 's/d'))), ' · ', if(startsWith(string(item()?['MedEquipo']), '{'), json(string(item()?['MedEquipo']))?['Value'], string(coalesce(item()?['MedEquipo'], 's/d'))), ' · vence ', formatDateTime(item()?['MedFechaVencimiento'], 'dd/MM/yyyy'))"
    'emailMessage/Body' = $mailBody
    'emailMessage/Importance' = "Normal"
}) @{ Calcular_hito = @("Succeeded") }
$loopActions.Marcar_notificado = New-ConnectorAction "shared_sharepointonline" "shared_sharepointonline" "PatchFileItem" ([ordered]@{
    dataset = $SiteUrl
    table = $LibraryId
    id = "@item()?['Id']"
    'item/MedAlertaEnviada' = "@outputs('Calcular_hito')"
}) @{ Enviar_correo = @("Succeeded") }
$alertActions.Recorrer_documentos = [ordered]@{
    type = "Foreach"
    foreach = "@body('Filtrar_a_notificar')"
    actions = $loopActions
    runAfter = @{ Filtrar_a_notificar = @("Succeeded") }
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
