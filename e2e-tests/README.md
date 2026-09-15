# e2e-tests

Pruebas End-to-End con Selenium (Fase 6, sección 38 de la especificación maestra).

## Qué prueba

El flujo completo contra el stack real levantado con Docker Compose:

```text
Login -> Dashboard -> Aeropuertos (mapa) -> Crear itinerario
      -> Validar aeropuerto (implícito, vía backend) -> Guardar
      -> Verificar en la lista -> Editar -> Eliminar
```

Un único test (`ItineraryFullFlowE2ETest`) cubre el flujo principal de punta a punta,
tal como pide la sección 38 para Nivel 1 (el flujo de RabbitMQ/Notification del mismo
punto se agrega en Nivel 2, cuando exista Notification Service).

## Requisitos

- El stack completo corriendo (`docker compose up --build` desde `itinerarios-infrastructure`).
- Chrome/Chromium instalado en la máquina que ejecuta los tests. Selenium 4.6+ incluye
  **Selenium Manager**, que resuelve automáticamente el `chromedriver` compatible — no hace
  falta instalarlo ni declarar WebDriverManager como dependencia.

## Ejecutar

```bash
cd e2e-tests
mvn clean test
```

Propiedades de sistema configurables:

| Propiedad | Default | Descripción |
|---|---|---|
| `e2e.baseUrl` | `http://localhost:4200` | URL del frontend Angular |
| `e2e.headless` | `true` | `false` para ver el navegador durante la ejecución local |

Ejemplo:

```bash
mvn clean test -De2e.baseUrl=http://localhost:4200 -De2e.headless=false
```

## Nota de acoplamiento a la UI

Estas pruebas usan selectores CSS/XPath que dependen de la estructura real de los
componentes Angular (ids de inputs, texto de botones, clases CSS). Si se renombra un
`id` o el texto de un botón en `itinerarios-frontend`, este test se rompe — es
intencional: es exactamente la señal de que cambió un contrato de UI relevante
(sección 100: "regla de compatibilidad").
