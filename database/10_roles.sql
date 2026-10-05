-- 10_roles.sql
-- Dos capas de roles:
--   1) Roles técnicos de PostgreSQL (NOLOGIN) para acceso directo a la base de
--      datos por parte del equipo DBA/analistas/auditores. No son usados por la API.
--   2) `app_api` (LOGIN): único rol con el que se conecta el backend, con
--      privilegios mínimos. La autorización fina (admin/operador/analista/
--      auditor/cliente) vive en la columna usuarios.rol y se resuelve en la API.
--
-- Contraseña de app_api: valor de desarrollo, igual de propósito que
-- POSTGRES_PASSWORD en docker/docker-compose.yml. En un entorno real se
-- gestionaría por secreto/variable de entorno, nunca committeada.

-- Los roles son objetos de todo el clúster (no de una base de datos en
-- particular), así que CREATE ROLE falla con "already exists" si este script
-- se ejecuta contra una segunda base (p.ej. datamarket_test) en el mismo
-- clúster. Se crean de forma idempotente para poder reconstruir cualquier
-- base del clúster ejecutando los mismos scripts sin modificarlos.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_admin') THEN
        CREATE ROLE db_admin NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_developer') THEN
        CREATE ROLE db_developer NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_analyst') THEN
        CREATE ROLE db_analyst NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_operator') THEN
        CREATE ROLE db_operator NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_auditor') THEN
        CREATE ROLE db_auditor NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_api') THEN
        CREATE ROLE app_api LOGIN PASSWORD 'app_api_dev_only'
            NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    END IF;
END
$$;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- db_admin: control total sobre el esquema de la aplicación.
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO db_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO db_admin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO db_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO db_admin;

-- db_developer: lectura/escritura de datos para desarrollo, sin administrar roles.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO db_developer;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO db_developer;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO db_developer;

-- db_analyst: solo consulta, nunca elimina ni modifica registros.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO db_analyst;

-- db_operator: consulta operativa de usuarios, sin acceso al hash de contraseña.
GRANT SELECT (id, username, rol, activo, creado_en) ON usuarios TO db_operator;

-- db_operator: consulta operativa del catálogo y pedidos (sin DELETE). El
-- proceso de compra en sí se ejecuta vía realizar_compra() (SECURITY
-- DEFINER, database/08_procedures.sql), no con privilegios de escritura
-- directos de db_operator sobre estas tablas.
GRANT SELECT ON categorias, clientes, productos, inventario, pedidos, detalle_pedido, pagos
    TO db_operator;
GRANT SELECT ON inventario_bajo, resumen_ventas_periodo, resumen_compras_cliente TO db_operator;

-- db_auditor: solo lectura de auditoría, de usuarios (sin hash) y de las
-- tablas de negocio auditadas (para poder cruzar auditoria.datos_nuevos con
-- el estado actual); nunca administra la base ni modifica nada.
GRANT SELECT ON auditoria TO db_auditor;
GRANT SELECT (id, username, rol, activo) ON usuarios TO db_auditor;
GRANT SELECT ON categorias, clientes, productos, inventario, pedidos, detalle_pedido, pagos
    TO db_auditor;
GRANT SELECT ON inventario_bajo, resumen_ventas_periodo, resumen_compras_cliente TO db_auditor;

-- app_api: privilegios mínimos.
--   - SELECT de columnas específicas de usuarios: necesario para que el
--     endpoint de login pueda leer password_hash y verificarlo con bcrypt.
--   - EXECUTE sobre crear_usuario: único camino de escritura hacia `usuarios`.
--   - Sin INSERT/UPDATE/DELETE directo sobre usuarios ni privilegios sobre
--     auditoria (la auditoría se escribe vía trigger SECURITY DEFINER).
GRANT CONNECT ON DATABASE datamarket TO app_api;
GRANT USAGE ON SCHEMA public TO app_api;
GRANT SELECT (id, username, password_hash, rol, cliente_id, activo) ON usuarios TO app_api;
GRANT EXECUTE ON FUNCTION crear_usuario(VARCHAR, VARCHAR, VARCHAR, BIGINT) TO app_api;

-- Proceso de compra: igual que crear_usuario, app_api solo tiene EXECUTE
-- sobre la función, nunca INSERT/UPDATE directo en pedidos/detalle_pedido/
-- inventario/pagos (ver database/08_procedures.sql).
GRANT EXECUTE ON FUNCTION realizar_compra(BIGINT, JSONB, VARCHAR) TO app_api;

-- Lectura de catálogo/pedidos para los endpoints de productos, inventario y
-- pedidos (GET /productos, GET /inventario, GET /pedidos). La escritura de
-- pedidos sigue pasando únicamente por realizar_compra(); app_api nunca
-- tiene INSERT/UPDATE/DELETE directo sobre estas tablas.
GRANT SELECT ON categorias, productos, inventario, clientes, pedidos, detalle_pedido, pagos
    TO app_api;
GRANT SELECT ON inventario_bajo TO app_api;
