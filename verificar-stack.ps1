<#
.SYNOPSIS
  Verificación de cierre de Nivel 1 y Nivel 2 (auditoría 2026-10-09, ADR-015).

.DESCRIPTION
  Ejecuta, en orden y deteniéndose en el primer fallo:
    0. Limpieza de carpetas vacías con llaves "{...}" (mkdir fallido).
    1. mvn -B clean verify en los 4 servicios backend (dentro de un contenedor Maven,
       no requiere Maven local).
    2. npm ci + npm test + build del frontend (contenedor Node 24).
    3. docker compose up --build y chequeos de salud / endpoints por el Gateway.
    4. (Opcional, -E2E) pruebas Selenium; requiere Maven y Chrome locales.
  Todo queda registrado en verificacion-<fecha>.log para adjuntarlo como evidencia.

.EXAMPLE
  cd itinerarios-infrastructure
  .\verificar-stack.ps1            # pasos 0-3
  .\verificar-stack.ps1 -E2E       # pasos 0-4
  .\verificar-stack.ps1 -SoloBuild # pasos 0-2 (sin levantar el stack)
#>
param(
    [switch]$E2E,
    [switch]$SoloBuild,
    [switch]$OmitirBuild,   # salta pasos 1-2 cuando ya pasaron (re-ejecuciones del paso 3)
    [switch]$MantenerStack
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot      # carpeta que contiene los 7 repos
$Infra = $PSScriptRoot
$Log = Join-Path $Infra ("verificacion-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $Log | Out-Null

function Paso($texto) { Write-Host "`n=== $texto ===" -ForegroundColor Cyan }
function Ok($texto)   { Write-Host "[OK] $texto" -ForegroundColor Green }
function Falla($texto) {
    Write-Host "[FALLA] $texto" -ForegroundColor Red
    Stop-Transcript | Out-Null
    Write-Host "Log: $Log"
    exit 1
}

try {
    # ---------------------------------------------------------------- 0
    Paso '0. Carpetas basura "{...}"'
    $basura = Get-ChildItem -Path $Raiz -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '{*' -and $_.FullName -notmatch '\\(node_modules|\.git|target)\\' }
    foreach ($d in $basura) {
        if (-not (Get-ChildItem -LiteralPath $d.FullName -Force)) {
            Remove-Item -LiteralPath $d.FullName -Force
            Write-Host "Eliminada (vacía): $($d.FullName)"
        } else {
            Write-Host "NO eliminada (tiene contenido, revisar a mano): $($d.FullName)" -ForegroundColor Yellow
        }
    }
    Ok 'Limpieza revisada'

    if (-not (Test-Path (Join-Path $Infra '.env'))) {
        Copy-Item (Join-Path $Infra '.env.example') (Join-Path $Infra '.env')
        Write-Host '.env creado desde .env.example (valores de desarrollo).' -ForegroundColor Yellow
    }

    if (-not $OmitirBuild) {
    # ---------------------------------------------------------------- 1
    Paso '1. Backend: mvn -B clean verify'
    docker volume create itinerarios-m2 | Out-Null
    foreach ($repo in 'itinerarios-airport-service','itinerarios-itinerary-service','itinerarios-notification','itinerarios-gateway') {
        $ruta = Join-Path $Raiz $repo
        Write-Host "--> $repo"
        docker run --rm -v "${ruta}:/app" -v itinerarios-m2:/root/.m2 -w /app `
            maven:3.9-eclipse-temurin-21 mvn -B -ntp clean verify
        if ($LASTEXITCODE -ne 0) { Falla "mvn verify en $repo (ver ADR-015, riesgos abiertos)" }
        Ok "$repo compila y sus tests pasan"
    }

    # ---------------------------------------------------------------- 2
    Paso '2. Frontend: npm ci + test + build'
    $fe = Join-Path $Raiz 'itinerarios-frontend'
    docker run --rm -v "${fe}:/app" -w /app node:24-alpine `
        sh -c "npm ci --no-audit --no-fund && npm test -- --watch=false && npm run build -- --configuration production"
    if ($LASTEXITCODE -ne 0) { Falla 'frontend' }
    Ok 'Frontend: tests y build en verde'
    }

    if ($SoloBuild) { Ok 'Modo -SoloBuild: fin'; return }

    # ---------------------------------------------------------------- 3
    Paso '3. docker compose up --build'
    Push-Location $Infra
    docker compose up --build -d
    if ($LASTEXITCODE -ne 0) { Pop-Location; Falla 'docker compose up' }
    Pop-Location

    function Esperar($url, $nombre, $intentos = 40) {
        for ($i = 1; $i -le $intentos; $i++) {
            try {
                $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
                if ($r.StatusCode -lt 400) { Ok "$nombre responde ($url)"; return }
            } catch { }
            Start-Sleep -Seconds 5
        }
        Falla "$nombre no respondió: $url (docker compose logs $nombre)"
    }

    Esperar 'http://localhost:8081/actuator/health' 'airport-service'
    Esperar 'http://localhost:8082/actuator/health' 'itinerary-service'
    Esperar 'http://localhost:8083/actuator/health' 'notification-service'
    Esperar 'http://localhost:8080/actuator/health' 'gateway'
    Esperar 'http://localhost:4200/' 'frontend'
    Esperar 'http://localhost:8081/swagger-ui.html' 'swagger airport'
    Esperar 'http://localhost:8082/swagger-ui.html' 'swagger itinerary'

    Paso '3b. Flujo de negocio por el Gateway (sesion de Keycloak, ADR-018)'
    # La API exige usuario: login OIDC real con el usuario tecnico e2e, por el frontend (mismo origen).
    $m = Select-String -Path (Join-Path $Infra '.env') -Pattern '^E2E_USER_PASSWORD=(.*)' -ErrorAction SilentlyContinue | Select-Object -First 1
    $e2ePass = if ($m) { $m.Matches[0].Groups[1].Value.Trim() } else { 'e2e-dev' }   # default de docker-compose.yml
    $front = 'http://localhost:4200'
    try {
        $null = Invoke-WebRequest "$front/api/itineraries" -UseBasicParsing
        Falla 'La API sin sesion deberia devolver 401'
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 401) { Ok 'API sin sesion -> 401' } else { Falla "API sin sesion devolvio $($_.Exception.Response.StatusCode.value__)" }
    }
    # curl.exe (incluido en Windows): Invoke-WebRequest de PS 5.1 pierde las cookies de las redirecciones.
    $jar = Join-Path $env:TEMP 'itinerarios-cookies.txt'; Remove-Item $jar -ErrorAction SilentlyContinue
    $form = (& curl.exe -s -L -c $jar -b $jar "$front/oauth2/authorization/keycloak") -join "`n"
    $action = [System.Net.WebUtility]::HtmlDecode(([regex]'action="([^"]+)"').Match($form).Groups[1].Value)
    $next = & curl.exe -s -c $jar -b $jar -o NUL -w '%{redirect_url}' --data-urlencode 'username=e2e' --data-urlencode "password=$e2ePass" $action
    $null = & curl.exe -s -c $jar -b $jar -o NUL $next
    $kc = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    foreach ($linea in Get-Content $jar) {
        $c = ($linea -replace '^#HttpOnly_', '') -split "`t"
        if ($c.Count -eq 7 -and $c[0] -eq 'localhost') { $kc.Cookies.Add((New-Object System.Net.Cookie($c[5], $c[6], $c[2], 'localhost'))) }
    }
    Remove-Item $jar -ErrorAction SilentlyContinue
    $yo = Invoke-RestMethod "$front/auth/me" -WebSession $kc
    Ok "Login Keycloak OK: $($yo.name)"
    $xsrf = @{ 'X-XSRF-TOKEN' = $kc.Cookies.GetCookies($front)['XSRF-TOKEN'].Value }

    $aeropuerto = Invoke-RestMethod "$front/api/airports/iata/BOG" -WebSession $kc
    Ok "Aeropuerto BOG: $($aeropuerto.name)"
    $null = Invoke-RestMethod "$front/api/airports/iata/MDE" -WebSession $kc

    $body = @{
        userName = 'verificacion'; departureAirportId = 'BOG'; arrivalAirportId = 'MDE'
        travelDate = (Get-Date).AddDays(30).ToString('yyyy-MM-dd'); durationMinutes = 60
    } | ConvertTo-Json
    $creado = Invoke-RestMethod -Method Post -Uri "$front/api/itineraries" -WebSession $kc `
        -ContentType 'application/json' -Body $body -Headers ($xsrf + @{ 'X-Correlation-ID' = 'verificacion-001' })
    Ok "Itinerario creado id=$($creado.id)"

    try {
        $null = Invoke-RestMethod -Method Post -Uri "$front/api/itineraries" -WebSession $kc -Headers $xsrf `
            -ContentType 'application/json' -Body ($body -replace '"MDE"','"ZZZ"')
        Falla 'Un aeropuerto inexistente debería devolver 400'
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 400) { Ok 'Aeropuerto inexistente -> 400' } else { Falla "Aeropuerto inexistente devolvió $code" }
    }

    Start-Sleep -Seconds 8   # ciclo del OutboxPublisher (2 s) + consumo
    $hist = Invoke-RestMethod "$front/api/notifications/itinerary/$($creado.id)" -WebSession $kc
    if (@($hist).Count -ge 1) { Ok 'Notificación registrada (Outbox -> RabbitMQ -> Notification)' }
    else { Falla 'No se registró la notificación del itinerario creado' }

    Invoke-RestMethod -Method Delete -Uri "$front/api/itineraries/$($creado.id)" -WebSession $kc -Headers $xsrf | Out-Null
    Ok 'Itinerario eliminado'

    Esperar 'http://localhost:9090/-/ready' 'prometheus'
    Esperar 'http://localhost:16686/' 'jaeger'

    # ---------------------------------------------------------------- 4
    if ($E2E) {
        Paso '4. Selenium E2E'
        Push-Location (Join-Path $Infra 'e2e-tests')
        # Maven global si existe; si no, el que dejó el Maven Wrapper en ~/.m2.
        $mvn = (Get-Command mvn -ErrorAction SilentlyContinue).Source
        if (-not $mvn) {
            $mvn = Get-ChildItem "$HOME\.m2\wrapper\dists" -Recurse -Filter mvn.cmd -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $mvn) { Pop-Location; Falla 'No se encontró Maven para Selenium' }
        # Socket temporal en ruta corta: con %TEMP% largo el HttpClient de Java falla en Windows.
        & $mvn -B -ntp clean test "-Djdk.net.unixdomain.tmpdir=$HOME" "-De2e.password=$e2ePass"
        $codigo = $LASTEXITCODE
        Pop-Location
        if ($codigo -ne 0) { Falla 'Selenium E2E' }
        Ok 'E2E en verde'
    }

    Write-Host "`nTODO OK. Adjuntar $Log como evidencia (evidence/)." -ForegroundColor Green
}
finally {
    if (-not $SoloBuild -and -not $MantenerStack) {
        Push-Location $Infra; docker compose down | Out-Null; Pop-Location
    }
    try { Stop-Transcript | Out-Null } catch { }
}
