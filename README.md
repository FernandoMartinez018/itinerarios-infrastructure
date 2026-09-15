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
| PostgreSQL airport_db | localhost:5433 |
| PostgreSQL itinerary_db | localhost:5434 |

El frontend y cualquier cliente externo deben usar **solo** el Gateway (puerto 8080).
Los puertos directos de Airport/Itinerary Service se exponen únicamente para debugging
local y Swagger; en un despliegue real no deberían quedar expuestos públicamente.

## Notification / RabbitMQ / Redis / Observabilidad

Comentados intencionalmente en `docker-compose.yml`. Se activan en Nivel 2 (Fase 7-11):
RabbitMQ, Redis, Notification Service, Jaeger, Prometheus, Grafana, LocalStack.
No agregarlos antes de cerrar Nivel 1 (regla 8 de la especificación maestra).

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
