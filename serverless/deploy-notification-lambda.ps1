<#
.SYNOPSIS
  Simulacion serverless de Notification (Nivel 2, secciones 31-32, 77, 106).

.DESCRIPTION
  1. Empaqueta itinerarios-notification como ZIP de Lambda (clases + lib/*.jar).
  2. Levanta LocalStack (perfil "serverless") y crea SendNotificationFunction (java21).
  3. Invoca la funcion con un ItineraryCreatedEvent de prueba.
  4. Verifica via Gateway que el historial registro la notificacion (SENT).
  Requiere el stack principal arriba (docker compose up) para Postgres y Gateway.
  Nota: LocalStack no reproduce RabbitMQ -> Lambda (seccion 32); se invoca directo.
#>
# Continue: en PowerShell 5.1 el stderr de docker/awslocal se volveria error fatal con 'Stop'.
# Los fallos reales se detectan con $LASTEXITCODE (funcion Aws y chequeos explicitos).
$ErrorActionPreference = 'Continue'
$Infra = Split-Path -Parent $PSScriptRoot
$Notif = Join-Path (Split-Path -Parent $Infra) 'itinerarios-notification'
$Funcion = 'SendNotificationFunction'
$Bucket = 'notification-lambda'
$Utf8 = New-Object System.Text.UTF8Encoding($false)   # sin BOM: el AWS CLI no lo acepta

function Ok($t) { Write-Host "[OK] $t" -ForegroundColor Green }
function Aws { docker exec localstack awslocal @args; if ($LASTEXITCODE -ne 0) { throw "awslocal $args" } }

# Valores de .env (mismos que usa notification-service en Compose)
$envVars = @{}
Get-Content (Join-Path $Infra '.env') | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } |
    ForEach-Object { $envVars[$Matches[1]] = $Matches[2] }

Write-Host '=== 1. Empaquetado ZIP de Lambda ===' -ForegroundColor Cyan
docker volume create itinerarios-m2 | Out-Null
docker run --rm -v "${Notif}:/app" -v itinerarios-m2:/root/.m2 -w /app maven:3.9-eclipse-temurin-21 sh -c `
    "mvn -B -ntp -q -DskipTests package dependency:copy-dependencies -DincludeScope=runtime -DoutputDirectory=target/lambda/lib && cp -r target/classes/. target/lambda/ && rm -f target/notification-lambda.zip && jar cfM target/notification-lambda.zip -C target/lambda ."
if ($LASTEXITCODE -ne 0) { throw 'Empaquetado fallido' }
Ok ("ZIP: {0:N1} MB" -f ((Get-Item (Join-Path $Notif 'target\notification-lambda.zip')).Length / 1MB))

Write-Host '=== 2. LocalStack + SendNotificationFunction ===' -ForegroundColor Cyan
Push-Location $Infra; docker compose --profile serverless up -d localstack; Pop-Location
for ($i = 0; $i -lt 30; $i++) {
    try { if ((Invoke-RestMethod 'http://localhost:4566/_localstack/health').services.lambda -match 'available|running') { break } } catch { }
    Start-Sleep -Seconds 3
}
Ok 'LocalStack listo'

$tmp = Join-Path $env:TEMP 'notif-lambda'; New-Item -ItemType Directory -Force $tmp | Out-Null
[IO.File]::WriteAllText("$tmp\env.json", (@{ Variables = @{
    DB_HOST = 'postgres-notification'; DB_PORT = '5432'; DB_NAME = 'notification_db'
    DB_USERNAME = $envVars['NOTIFICATION_DB_USER']; DB_PASSWORD = $envVars['NOTIFICATION_DB_PASSWORD']
    RABBITMQ_HOST = 'rabbitmq' } } | ConvertTo-Json -Compress), $Utf8)
$itineraryId = Get-Random -Minimum 900000 -Maximum 999999
[IO.File]::WriteAllText("$tmp\event.json", (@{
    eventId = [guid]::NewGuid().ToString(); eventType = 'ItineraryCreatedEvent'
    occurredAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); itineraryId = $itineraryId
    userName = 'lambda-localstack'; departureAirportId = 'BOG'; arrivalAirportId = 'MDE'
    travelDate = (Get-Date).AddDays(15).ToString('yyyy-MM-dd'); durationMinutes = 60 } | ConvertTo-Json -Compress), $Utf8)

docker cp (Join-Path $Notif 'target\notification-lambda.zip') localstack:/tmp/notification-lambda.zip | Out-Null
docker cp "$tmp\env.json" localstack:/tmp/env.json | Out-Null
docker cp "$tmp\event.json" localstack:/tmp/event.json | Out-Null

# Por S3: el ZIP supera el limite de 50 MB de subida directa.
docker exec localstack awslocal s3 mb "s3://$Bucket" 2>$null | Out-Null
Aws s3 cp /tmp/notification-lambda.zip "s3://$Bucket/notification-lambda.zip" | Out-Null
docker exec localstack awslocal lambda delete-function --function-name $Funcion 2>$null | Out-Null
Aws lambda create-function --function-name $Funcion --runtime java21 `
    --handler com.itinerarios.notification.lambda.NotificationLambdaHandler::handleRequest `
    --role arn:aws:iam::000000000000:role/lambda-notification `
    --code "S3Bucket=$Bucket,S3Key=notification-lambda.zip" `
    --timeout 120 --memory-size 1024 --environment file:///tmp/env.json | Out-Null
Aws lambda wait function-active-v2 --function-name $Funcion
Ok "$Funcion creada (java21)"

Write-Host '=== 3. Invocacion con ItineraryCreatedEvent ===' -ForegroundColor Cyan
# awslocal de LocalStack 4.0 es AWS CLI v1: no admite --cli-binary-format (el payload va tal cual).
Aws lambda invoke --function-name $Funcion `
    --payload file:///tmp/event.json /tmp/out.json | Out-Null
$respuesta = docker exec localstack cat /tmp/out.json
Write-Host "Respuesta Lambda: $respuesta"
if ($respuesta -notmatch 'PROCESSED') { throw "La Lambda no proceso el evento: $respuesta" }

Write-Host '=== 4. Verificacion del historial via Gateway ===' -ForegroundColor Cyan
# Se busca en el JSON crudo: en PS 5.1 Invoke-RestMethod entrega el arreglo anidado y Where-Object no lo recorre.
$hist = (Invoke-WebRequest -UseBasicParsing "http://localhost:8080/api/notifications/itinerary/$itineraryId").Content
if ($hist -notmatch '"status":"SENT"') { throw "Sin notificacion SENT para itinerario $itineraryId" }
Ok "Notificacion SENT registrada por la Lambda (itinerario $itineraryId)"
