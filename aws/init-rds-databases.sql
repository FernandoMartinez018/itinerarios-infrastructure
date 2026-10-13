-- Bases logicas por microservicio en la instancia RDS (seccion 56): cada servicio tiene su
-- propia base y su propio usuario, sin permisos sobre las demas (aislamiento, seccion 12).
-- keycloak_db: base de Keycloak en modo produccion (seguridad S2S, paso 31).
-- Uso (passwords por variable, nunca en Git):
--   psql "host=<endpoint> dbname=itinerarios user=itinerarios_admin sslmode=require" \
--     -v airport_pw=... -v itinerary_pw=... -v notification_pw=... -v keycloak_pw=... -f init-rds-databases.sql

SELECT format('CREATE ROLE airport_user LOGIN PASSWORD %L', :'airport_pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'airport_user') \gexec
SELECT format('CREATE ROLE itinerary_user LOGIN PASSWORD %L', :'itinerary_pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'itinerary_user') \gexec
SELECT format('CREATE ROLE notification_user LOGIN PASSWORD %L', :'notification_pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'notification_user') \gexec
SELECT format('CREATE ROLE keycloak_user LOGIN PASSWORD %L', :'keycloak_pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak_user') \gexec

-- RDS: el admin debe ser miembro del rol para poder asignarlo como OWNER.
GRANT airport_user, itinerary_user, notification_user, keycloak_user TO itinerarios_admin;

SELECT 'CREATE DATABASE airport_db OWNER airport_user'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'airport_db') \gexec
SELECT 'CREATE DATABASE itinerary_db OWNER itinerary_user'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'itinerary_db') \gexec
SELECT 'CREATE DATABASE notification_db OWNER notification_user'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'notification_db') \gexec
SELECT 'CREATE DATABASE keycloak_db OWNER keycloak_user'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak_db') \gexec

-- Nadie fuera del dueno se conecta a cada base.
REVOKE CONNECT ON DATABASE airport_db, itinerary_db, notification_db, keycloak_db FROM PUBLIC;
