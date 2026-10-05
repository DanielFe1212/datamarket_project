-- 01_database.sql
-- La base de datos `datamarket` ya se crea vía POSTGRES_DB en docker/docker-compose.yml.
-- Este script queda como punto de extensión para configuración a nivel de base de datos
-- (timezone, locale, etc.) cuando se agreguen los demás módulos del laboratorio.

ALTER DATABASE datamarket SET timezone TO 'UTC';
