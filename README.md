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

## Levantar Nivel 1

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

El frontend y cualquier cliente externo deben usar **solo** el Gateway (puerto 8080).
Los puertos directos de Airport/Itinerary Service se exponen únicamente para debugging
local y Swagger; en un despliegue real no deberían quedar expuestos públicamente.

## Notification / Redis / Observabilidad

Comentados intencionalmente en `docker-compose.yml`. Notification Service se activa en
Fase 8, Redis en Fase 9, y observabilidad (Jaeger/Prometheus/Grafana/LocalStack) en
Fase 9-11. RabbitMQ ya está activo desde Fase 7: Itinerary Service publica
`ItineraryCreatedEvent` en el exchange `itinerary.events`, aunque todavía no hay ningún
consumidor — los mensajes se acumulan sin consumir hasta que Notification Service
exista (Fase 8). Puedes verificarlo en la pestaña "Exchanges" de
http://localhost:15672.

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
