# itinerarios-infrastructure

Orquestación local de Nivel 1 — Sistema de Itinerarios Personales.

## Requisito de estructura de carpetas

Este `docker-compose.yml` usa `context: ../itinerarios-<servicio>`, por lo que los siete
repositorios deben estar clonados **como hermanos**, dentro de una misma carpeta padre:

```text
workspace/
├── itinerarios-airport-service/
├── itinerarios-itinerary-service/
├── itinerarios-notification/
├── itinerarios-gateway/
├── itinerarios-frontend/
├── itinerarios-infrastructure/   <- ejecutar docker compose desde aquí
└── itinerarios-docs/
```

## Levantar el stack

```bash
cp .env.example .env
# editar .env con contraseñas reales (nunca commitear .env)

docker compose up --build
```

Servicios expuestos:

| Servicio | URL |
|---|---|
| Frontend Angular | http://localhost:4200 |
| Gateway | http://localhost:8080 |
| Airport Service (directo, solo debug) | http://localhost:8081/swagger-ui.html |
| Itinerary Service (directo, solo debug) | http://localhost:8082/swagger-ui.html |
| Notification Service (directo, solo debug) | http://localhost:8083/swagger-ui.html |
| RabbitMQ Management UI | http://localhost:15672 (guest/guest por defecto) |
| Jaeger (trazas distribuidas) | http://localhost:16686 |
| Prometheus (métricas) | http://localhost:9090 |
| Grafana (dashboards) | http://localhost:3000 (admin/admin por defecto) |
| PostgreSQL airport_db | localhost:5433 |
| PostgreSQL itinerary_db | localhost:5434 |
| PostgreSQL notification_db | localhost:5435 |
| Redis | localhost:6379 |
| LocalStack (perfil `serverless`) | http://localhost:4566 |

El frontend y cualquier cliente externo deben usar **solo** el Gateway (puerto 8080).
Los puertos directos de Airport/Itinerary Service se exponen únicamente para debugging
local y Swagger; en un despliegue real no deberían quedar expuestos públicamente.

## Servicios activos y perfiles

Todo el stack de Nivel 1 y Nivel 2 está activo en `docker-compose.yml`: los 5 servicios
de aplicación, las 3 bases PostgreSQL, Redis, RabbitMQ, Jaeger, OpenTelemetry Collector,
Prometheus y Grafana.

LocalStack (simulación de AWS Lambda para Notification, secciones 31-32) va en el perfil
`serverless` para no frenar el arranque del stack principal:

```bash
docker compose --profile serverless up -d localstack
curl http://localhost:4566/_localstack/health
```

RabbitMQ: Itinerary Service escribe el evento en `outbox_events` y el `OutboxPublisher`
lo publica en el exchange `itinerary.events`; Notification Service lo consume desde
`notification.itinerary-created.queue` (ver http://localhost:15672).

## Apagar y limpiar

```bash
docker compose down
docker compose down -v   # además borra los volúmenes de datos
```

## Pruebas E2E

Ver `e2e-tests/README.md`. Requieren el stack completo corriendo (este mismo
`docker-compose.yml`) y Chrome/Chromium instalado localmente.

```bash
docker compose up --build -d
cd e2e-tests && mvn clean test
```
