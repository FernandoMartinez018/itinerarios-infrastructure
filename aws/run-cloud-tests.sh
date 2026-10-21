#!/usr/bin/env bash
# Paso 29 (seccion 111): pruebas cloud integradas. Enciende todo, prueba y APAGA SIEMPRE
# (trap EXIT), porque la cuenta no tiene creditos (ADR-017). Termina con un inventario.
# Paso 32 (demo de entrega): --keep NO apaga e imprime las URL; --down solo apaga.
#
# Requisitos: AWS CLI v2 con sesion (aws login), gh autenticado, Python 3 con psycopg,
# Maven (Lambda y Selenium), Chrome. Uso, desde itinerarios-infrastructure:
#   bash aws/run-cloud-tests.sh [--keep|--down] [archivo-de-log]
set -uo pipefail
MODE=test; case "${1:-}" in --keep|--down) MODE="${1#--}"; shift;; esac

REGION=us-east-1
AWS="${AWS_CLI:-aws}"
GH="${GH_CLI:-gh}"
MVN="${MVN:-mvn}"
OWNER=FernandoMartinez018
HERE="$(cd "$(dirname "$0")" && pwd)"
CFN="$HERE/cloudformation"
NOTIF="$HERE/../../itinerarios-notification"
LOG="${1:-$HERE/cloud-tests-$(date +%Y%m%d-%H%M).log}"
BUCKET="itinerarios-lambda-code-$("$AWS" sts get-caller-identity --query Account --output text)"
PASS=0; FAIL=0

aws_() { "$AWS" --region "$REGION" "$@"; }
# Git Bash convierte "/itinerarios/..." en rutas de Windows; el CLI de AWS es un .exe.
ssm_() { MSYS_NO_PATHCONV=1 "$AWS" --region "$REGION" ssm "$@"; }
winpath() { command -v cygpath >/dev/null && cygpath -w "$1" || echo "$1"; }
out() { aws_ cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }
log() { echo "$*" | tee -a "$LOG"; }
check() { # check "<descripcion>" <condicion-bash>
  if ( set +o pipefail; eval "$2" ); then PASS=$((PASS+1)); log "  [OK]    $1"; else FAIL=$((FAIL+1)); log "  [FALLA] $1"; fi
}
deploy() { aws_ cloudformation deploy --stack-name "$1" --template-file "$(winpath "$CFN/$2")" --no-fail-on-empty-changeset "${@:3}" >/dev/null; }

teardown() {
  log ""; log "== Apagado $(date +%T) (siempre se ejecuta)"
  aws_ cloudformation delete-stack --stack-name itinerarios-ecs
  aws_ cloudformation delete-stack --stack-name itinerarios-lambda
  for s in itinerarios-ecs itinerarios-lambda; do aws_ cloudformation wait stack-delete-complete --stack-name $s; done
  # RDS despues: exporta el Endpoint que importan ECS y Lambda (borrarlo antes es rechazado).
  aws_ cloudformation delete-stack --stack-name itinerarios-rds
  aws_ cloudformation wait stack-delete-complete --stack-name itinerarios-rds
  aws_ s3 rm "s3://$BUCKET" --recursive --only-show-errors 2>/dev/null; aws_ s3api delete-bucket --bucket "$BUCKET" 2>/dev/null
  ssm_ delete-parameters --names /itinerarios/db/airport_password /itinerarios/db/itinerary_password \
       /itinerarios/db/notification_password /itinerarios/rabbitmq/password /itinerarios/db/keycloak_password \
       /itinerarios/keycloak/admin_password /itinerarios/keycloak/realm /itinerarios/oauth2/gateway_secret \
       /itinerarios/oauth2/itinerary_secret /itinerarios/keycloak/test_user_email \
       /itinerarios/keycloak/test_user_password /itinerarios/grafana/admin_password >/dev/null 2>&1
  ssm_ delete-parameters --names /itinerarios/observability/prometheus_yml /itinerarios/observability/alert_rules        /itinerarios/observability/grafana_datasources /itinerarios/observability/grafana_dashboards        /itinerarios/observability/grafana_dashboard_json >/dev/null 2>&1
  for r in airport-service itinerary-service notification gateway frontend; do
    ids=$(aws_ ecr list-images --repository-name itinerarios-$r --query "imageIds[].imageDigest" --output text | tr '\t' '\n' | sort -u | sed 's/^/imageDigest=/' | tr '\n' ' ')
    [ -n "$ids" ] && aws_ ecr batch-delete-image --repository-name itinerarios-$r --image-ids $ids >/dev/null
  done
  deploy itinerarios-network 03-network.yaml --parameter-overrides AdminCidr= AdminCidr2=
  log "== Inventario final (vacio = OK) $(date +%T)"
  log "RDS=[$(aws_ rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text)] ECS=[$(aws_ ecs list-clusters --query clusterArns --output text)] Lambda=[$(aws_ lambda list-functions --query 'Functions[].FunctionName' --output text)] S3=[$("$AWS" s3api list-buckets --query 'Buckets[].Name' --output text)]"
  log "IPv4=[$(aws_ ec2 describe-network-interfaces --query 'NetworkInterfaces[?Association.PublicIp].Association.PublicIp' --output text)] SSM=[$(ssm_ describe-parameters --query 'Parameters[].Name' --output text)] Secrets=[$(aws_ secretsmanager list-secrets --query 'SecretList[].Name' --output text)] SG-externo=[$(aws_ ec2 describe-security-groups --query 'SecurityGroups[].IpPermissions[].IpRanges[].CidrIp' --output text)]"
  log "Resultado: $PASS OK, $FAIL fallas"
}
[[ "$MODE" = down ]] && { teardown; exit 0; }
# En --keep un fallo deja lo encendido a proposito: se apaga con --down cuando el usuario lo ordene.
[[ "$MODE" = test ]] && trap teardown EXIT

log "# Paso 29/32 - Pruebas cloud integradas, modo $MODE ($(date '+%F %T'))"
# ---------------------------------------------------------------- encendido
# IPs de salida: la red puede balancear entre 2 ISP (HTTPS y TCP salen por enlaces distintos).
IPS=$( { for i in 1 2 3 4 5 6; do curl -s --max-time 10 https://checkip.amazonaws.com
          curl -s --max-time 10 http://portquiz.net:5432 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1; done; } \
       | tr -d '\r' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
N=$(echo "$IPS" | grep -c .)
[ "$N" -ge 1 ] && [ "$N" -le 2 ] || { log "Se detectaron $N IPs de salida (se admiten 1-2); abortando sin encender nada"; trap - EXIT; exit 1; }
CIDR="$(echo "$IPS" | sed -n 1p)/32"; CIDR2=""; [ "$N" = 2 ] && CIDR2="$(echo "$IPS" | sed -n 2p)/32"
log "== Encendido $(date +%T)"
log "Rangos admin detectados: $N"
deploy itinerarios-network 03-network.yaml --parameter-overrides AdminCidr="$CIDR" AdminCidr2="$CIDR2"
for p in db/airport_password db/itinerary_password db/notification_password rabbitmq/password \
         db/keycloak_password keycloak/admin_password oauth2/gateway_secret oauth2/itinerary_secret \
         keycloak/test_user_password grafana/admin_password; do
  ssm_ put-parameter --name "/itinerarios/$p" --type SecureString --overwrite \
       --value "$(python -c 'import secrets; print(secrets.token_urlsafe(24))')" >/dev/null
done
# Realm de Keycloak (sin secretos: placeholders ${...}) como String compacto en SSM; lo lee la tarea ECS.
python -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(',',':')))" \
  "$(winpath "$HERE/../keycloak/itinerarios-realm.json")" > realm.min.json
ssm_ put-parameter --name /itinerarios/keycloak/realm --type String --overwrite \
     --value "file://$(winpath "$PWD/realm.min.json")" >/dev/null && rm -f realm.min.json
# Usuario de prueba de Keycloak: correo desde el entorno o el .env local (fuera de Git).
TEST_USER_EMAIL="${TEST_USER_EMAIL:-$(grep -E '^TEST_USER_EMAIL=' "$HERE/../.env" 2>/dev/null | cut -d= -f2-)}"
ssm_ put-parameter --name /itinerarios/keycloak/test_user_email --type String --overwrite \
     --value "${TEST_USER_EMAIL:-tester@itinerarios.local}" >/dev/null
# Configuracion de observabilidad (sin secretos) que las tareas ECS escriben a disco al arrancar.
OBS="$HERE/../observability"
for kv in prometheus_yml=aws/prometheus.yml alert_rules=alert-rules.yml grafana_datasources=aws/grafana-datasources.yaml           grafana_dashboards=aws/grafana-dashboards.yaml grafana_dashboard_json=dashboards/itinerarios-overview.json; do
  # SSM rechaza "{{" en valores: se sube como <% %> y la tarea ECS lo restaura con sed.
  sed 's/{{/<%/g; s/}}/%>/g' "$OBS/${kv#*=}" > obs.tmp
  ssm_ put-parameter --name "/itinerarios/observability/${kv%%=*}" --type String --overwrite        --value "file://$(winpath "$PWD/obs.tmp")" >/dev/null || exit 1
done
rm -f obs.tmp
getp() { ssm_ get-parameter --name "/itinerarios/$1" --with-decryption --query Parameter.Value --output text; }

# Imagenes: si falta :latest en ECR se regenera re-ejecutando el CI de main (push-image por OIDC).
declare -A RUN
for r in airport-service itinerary-service notification gateway frontend; do
  aws_ ecr describe-images --repository-name itinerarios-$r --image-ids imageTag=latest >/dev/null 2>&1 && continue
  RUN[$r]=$("$GH" run list -R $OWNER/itinerarios-$r -b main -w CI -L 1 --json databaseId --jq '.[0].databaseId')
  "$GH" run rerun "${RUN[$r]}" -R $OWNER/itinerarios-$r >/dev/null
done
# ZIP de la Lambda mientras tanto
(cd "$NOTIF" && rm -rf target/lambda && "$MVN" -B -ntp -q -DskipTests package dependency:copy-dependencies \
   -DincludeScope=runtime -DoutputDirectory=target/lambda/lib && cp -r target/classes/. target/lambda/ && python - <<'EOF'
import os, zipfile
with zipfile.ZipFile('target/notification-lambda.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for d, _, fs in os.walk('target/lambda'):
        for f in fs:
            p = os.path.join(d, f); z.write(p, os.path.relpath(p, 'target/lambda').replace(os.sep, '/'))
EOF
) || exit 1
aws_ s3api create-bucket --bucket "$BUCKET" >/dev/null
aws_ s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws_ s3 cp "$(winpath "$NOTIF/target/notification-lambda.zip")" "s3://$BUCKET/notification-lambda.zip" --only-show-errors

deploy itinerarios-rds 04-rds.yaml --parameter-overrides PubliclyAccessible=true || exit 1
export EP=$(out itinerarios-rds Endpoint)
export MPW=$(aws_ secretsmanager get-secret-value --secret-id "$(out itinerarios-rds MasterSecretArn)" --query SecretString --output text | python -c "import json,sys; print(json.load(sys.stdin)['password'])")
export APW=$(getp db/airport_password) IPW=$(getp db/itinerary_password) NPW=$(getp db/notification_password)
export KPW=$(getp db/keycloak_password)
python - <<'EOF' || exit 1
# Misma logica que aws/init-rds-databases.sql (sin depender de psql/Docker).
import os, psycopg
from psycopg import sql
with psycopg.connect(host=os.environ["EP"], dbname="itinerarios", user="itinerarios_admin",
                     password=os.environ["MPW"], sslmode="require", autocommit=True) as c:
    for s, pw in {"airport": os.environ["APW"], "itinerary": os.environ["IPW"], "notification": os.environ["NPW"],
                  "keycloak": os.environ["KPW"]}.items():
        role, db = f"{s}_user", f"{s}_db"
        verb = "ALTER" if c.execute("select 1 from pg_roles where rolname=%s", (role,)).fetchone() else "CREATE"
        c.execute(sql.SQL(verb + " ROLE {} LOGIN PASSWORD {}").format(sql.Identifier(role), sql.Literal(pw)))
        c.execute(sql.SQL("GRANT {} TO itinerarios_admin").format(sql.Identifier(role)))
        if not c.execute("select 1 from pg_database where datname=%s", (db,)).fetchone():
            c.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(sql.Identifier(db), sql.Identifier(role)))
        c.execute(sql.SQL("REVOKE CONNECT ON DATABASE {} FROM PUBLIC").format(sql.Identifier(db)))
EOF

for r in "${!RUN[@]}"; do
  until [ "$("$GH" run view "${RUN[$r]}" -R $OWNER/itinerarios-$r --json status --jq .status)" = completed ]; do sleep 15; done
  [ "$("$GH" run view "${RUN[$r]}" -R $OWNER/itinerarios-$r --json conclusion --jq .conclusion)" = success ] || { log "CI de $r fallo"; exit 1; }
done
deploy itinerarios-ecs 05-ecs.yaml --capabilities CAPABILITY_IAM --parameter-overrides AdminCidr="$CIDR" AdminCidr2="$CIDR2" ImageTag=latest || exit 1
deploy itinerarios-lambda 06-lambda.yaml --capabilities CAPABILITY_IAM --parameter-overrides CodeBucket="$BUCKET" DbPassword="$NPW" || exit 1

# IP publica de la tarea de un servicio ECS (sin ALB, ADR-017): pubip GatewayService
pubip() {
  local svc task eni
  svc=$(aws_ ecs list-services --cluster itinerarios-ecs --query "serviceArns[?contains(@,'$1')]" --output text)
  task=$(aws_ ecs list-tasks --cluster itinerarios-ecs --service-name "$svc" --query "taskArns[0]" --output text)
  eni=$(aws_ ecs describe-tasks --cluster itinerarios-ecs --tasks "$task" --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)
  aws_ ec2 describe-network-interfaces --network-interface-ids "$eni" --query 'NetworkInterfaces[0].Association.PublicIp' --output text
}
GW="http://$(pubip GatewayService):8080"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
for i in $(seq 1 60); do curl -sf --max-time 5 "$GW/actuator/health" >/dev/null && break; sleep 5; done
# Gateway UP no basta: Airport/Itinerary/Notification arrancan Spring + Flyway contra RDS.
# Un fallo temprano abriria el Circuit Breaker y contaminaria las pruebas.
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$GW/api/airports/iata/MDE")" = 200 ] &&
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$GW/api/itineraries")" = 200 ] &&
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$GW/api/notifications")" = 200 ] && break
  sleep 10
done
log "Todo encendido y listo $(date +%T)"

# ---------------------------------------------------------------- pruebas
http() { curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$@"; }
body() { echo "{\"userName\":\"cloud-test\",\"departureAirportId\":\"BOG\",\"arrivalAirportId\":\"$1\",\"travelDate\":\"2026-12-20\",\"durationMinutes\":$2}"; }
post() { curl -s --max-time 60 -H 'Content-Type: application/json' -H "X-Correlation-ID: $1" -X POST "$GW/api/itineraries" -d "$2"; }
db() { python -c "
import os, sys, psycopg
with psycopg.connect(host=os.environ['EP'], dbname=sys.argv[1], user=sys.argv[2], password=os.environ[sys.argv[3]], sslmode='require') as c:
    print(c.execute(sys.argv[4]).fetchone()[0])" "$@"; }

log ""; log "== Pruebas"
TESTS_START_MS=$(( $(date +%s) * 1000 - 60000 ))  # ventana acotada para CloudWatch (sin ella el CLI pagina ~60 min)
check "1. Gateway health UP" 'curl -s --max-time 10 $GW/actuator/health | grep -q "\"status\":\"UP\""'
AIR=$(curl -s --max-time 60 "$GW/api/airports/iata/BOG")
check "2. BOG = El Dorado con coordenadas en Colombia" 'echo "$AIR" | python -c "import json,sys; a=json.load(sys.stdin); sys.exit(0 if a[\"icaoCode\"]==\"SKBO\" and -5<a[\"latitude\"]<14 and -82<a[\"longitude\"]<-66 else 1)"'
CREATED=$(post cloud-29-001 "$(body MDE 60)"); ID=$(echo "$CREATED" | python -c "import json,sys; print(json.load(sys.stdin).get('id',''))")
check "3a. POST valido -> 201 (id=$ID)" '[ -n "$ID" ]'
check "3b. Aeropuerto inexistente -> 400" '[ "$(http -H "Content-Type: application/json" -X POST $GW/api/itineraries -d "$(body ZZZ 60)")" = 400 ]'
check "3c. durationMinutes=0 -> 400" '[ "$(http -H "Content-Type: application/json" -X POST $GW/api/itineraries -d "$(body MDE 0)")" = 400 ]'
sleep 10
check "4a. Outbox PUBLISHED" '[ "$(db itinerary_db itinerary_user IPW "select status from outbox_events where aggregate_id='"'"'$ID'"'"'")" = PUBLISHED ]'
check "4b. Notificacion SENT via RabbitMQ en ECS" 'curl -s "$GW/api/notifications/itinerary/$ID" | grep -q "\"status\":\"SENT\""'
EVENT=$(db notification_db notification_user NPW "select event_id::text from notification_history where itinerary_id=$ID")
python -c "import json; json.dump({'eventId':'$EVENT','eventType':'ItineraryCreatedEvent','occurredAt':'2026-10-13T00:00:00Z','itineraryId':$ID,'userName':'cloud-test','departureAirportId':'BOG','arrivalAirportId':'MDE','travelDate':'2026-12-20','durationMinutes':60}, open('event.json','w'))"
aws_ lambda invoke --function-name SendNotificationFunction --cli-binary-format raw-in-base64-out \
     --payload "fileb://$(winpath "$PWD/event.json")" "$(winpath "$PWD/lambda-out.json")" >/dev/null
check "5. Lambda con el mismo eventId: PROCESSED y sigue 1 fila (idempotencia ECS+Lambda)" \
  'grep -q PROCESSED lambda-out.json && [ "$(db notification_db notification_user NPW "select count(*) from notification_history where event_id='"'"'$EVENT'"'"'")" = 1 ]'
rm -f event.json lambda-out.json

AIRSVC=$(aws_ ecs list-services --cluster itinerarios-ecs --query "serviceArns[?contains(@,'AirportService')]" --output text)
aws_ ecs update-service --cluster itinerarios-ecs --service "$AIRSVC" --desired-count 0 >/dev/null
aws_ ecs wait services-stable --cluster itinerarios-ecs --services "$AIRSVC"
for i in 1 2 3; do post cloud-29-cb-$i "$(body PEI 60)" >/dev/null; done
T0=$(date +%s%N); CODE=$(http -H 'Content-Type: application/json' -X POST "$GW/api/itineraries" -d "$(body PEI 60)"); MS=$(( ($(date +%s%N)-T0)/1000000 ))
check "6a. Airport caido -> 503 y breaker abierto falla rapido (${MS} ms)" '[ "$CODE" = 503 ] && [ $MS -lt 2000 ]'
aws_ ecs update-service --cluster itinerarios-ecs --service "$AIRSVC" --desired-count 1 >/dev/null
aws_ ecs wait services-stable --cluster itinerarios-ecs --services "$AIRSVC"
sleep 20
for i in $(seq 1 12); do [ "$(http -H 'Content-Type: application/json' -X POST "$GW/api/itineraries" -d "$(body CLO 30)")" = 201 ] && break; sleep 10; done
check "6b. Airport de vuelta -> breaker se recupera y POST 201" '[ "$(http -H "Content-Type: application/json" -X POST $GW/api/itineraries -d "$(body CLO 30)")" = 201 ]'

STREAMS=$(MSYS_NO_PATHCONV=1 "$AWS" --region $REGION logs filter-log-events --log-group-name /ecs/itinerarios-ecs \
          --filter-pattern '"cloud-29-001"' --start-time "$TESTS_START_MS" --end-time "$(date +%s%3N)"           --max-items 50 --query 'events[].logStreamName' --output text | tr '\t' '\n' | cut -d/ -f2 | sort -u | tr '\n' ' ')
check "7. Correlation ID cloud-29-001 en gateway, itinerary y airport [$STREAMS]" \
  'echo "$STREAMS" | grep -q gateway && echo "$STREAMS" | grep -q itinerary-service && echo "$STREAMS" | grep -q airport-service'
check "8a. PUT -> 200" '[ "$(http -H "Content-Type: application/json" -X PUT $GW/api/itineraries/$ID -d "$(body MDE 90)")" = 200 ]'
check "8b. DELETE -> 204" '[ "$(http -X DELETE $GW/api/itineraries/$ID)" = 204 ]'

# Selenium contra el frontend en ECS (nginx -> Gateway), con capturas de cada paso.
FE="http://$(pubip FrontendService)"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
E2E_SHOTS="$HERE/../e2e-tests/target/e2e-screenshots"
for i in $(seq 1 30); do [[ "$(http "$FE/")" = 200 ]] && break; sleep 10; done  # NOSONAR http de la demo (ADR-017)
check "9. Selenium E2E contra AWS ($FE)"   '(cd "$HERE/../e2e-tests" && "$MVN" -B -ntp -q test -De2e.baseUrl="$FE" -De2e.gatewayUrl="$GW" >>"$LOG" 2>&1)'  # NOSONAR http de la demo (ADR-017)
log "Pruebas terminadas $(date +%T)"

if [[ "$MODE" = keep ]]; then
  AIRIP=$(pubip AirportService); ITIP=$(pubip ItineraryService); NOIP=$(pubip NotificationService)
  KCIP=$(pubip KeycloakService); GRIP=$(pubip GrafanaService); PRIP=$(pubip PrometheusService); JAIP=$(pubip JaegerService)
  log ""; log "== URL de la demo (ENCENDIDO hasta: bash aws/run-cloud-tests.sh --down). Solo accesibles desde: $CIDR $CIDR2"  # NOSONAR http de la demo (ADR-017)
  log "Frontend            $FE/"  # NOSONAR http de la demo (ADR-017)
  log "Gateway (health)    $GW/actuator/health"  # NOSONAR http de la demo (ADR-017)
  log "Swagger Airport     http://$AIRIP:8081/swagger-ui.html"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
  log "Swagger Itinerary   http://$ITIP:8082/swagger-ui.html"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
  log "Swagger Notif.      http://$NOIP:8083/swagger-ui.html"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
  log "Grafana dashboard   http://$GRIP:3000/d/itinerarios-overview  (anonimo lectura; admin: SSM /itinerarios/grafana/admin_password)"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
  log "Prometheus alertas  http://$PRIP:9090/alerts"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
  log "Prometheus targets  http://$PRIP:9090/targets"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
  log "Jaeger              http://$JAIP:16686/search"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
  log "Keycloak (cuenta)   http://$KCIP:8080/realms/itinerarios/account  (usuario/clave temporal: SSM /itinerarios/keycloak/test_user_*)"  # NOSONAR demo sin ALB/TLS (ADR-017): solo accesible desde AdminCidr por SG
  log "Capturas Selenium   $E2E_SHOTS"
fi
[ "$FAIL" = 0 ]
