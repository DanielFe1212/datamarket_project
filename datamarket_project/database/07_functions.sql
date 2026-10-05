-- 07_functions.sql
-- Función SECURITY DEFINER para crear usuarios. app_api solo tiene EXECUTE sobre
-- esta función (ver 10_roles.sql); nunca tiene INSERT directo sobre `usuarios`.
-- El hash de la contraseña se calcula siempre en la API (bcrypt); esta función
-- nunca recibe ni procesa contraseñas en texto plano.

-- p_cliente_id es opcional (DEFAULT NULL): solo tiene sentido para rol
-- 'cliente' (vincula el login con su fila en clientes, ver 03/04). No se
-- fuerza con un CHECK que "cliente" deba traer cliente_id obligatoriamente:
-- esta función tampoco tiene forma de crear la fila de clientes (eso está
-- fuera del alcance de la API de usuarios), así que un cliente sin vincular
-- aún puede crearse y asociarse después.
CREATE OR REPLACE FUNCTION crear_usuario(
    p_username      VARCHAR,
    p_password_hash VARCHAR,
    p_rol           VARCHAR,
    p_cliente_id    BIGINT DEFAULT NULL
)
RETURNS TABLE (
    id          BIGINT,
    username    VARCHAR,
    rol         VARCHAR,
    cliente_id  BIGINT,
    activo      BOOLEAN,
    creado_en   TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_rol NOT IN ('admin', 'operador', 'analista', 'auditor', 'cliente') THEN
        RAISE EXCEPTION 'rol invalido: %', p_rol USING ERRCODE = '22023';
    END IF;

    IF p_password_hash !~ '^\$2[aby]\$\d{2}\$.{53}$' THEN
        RAISE EXCEPTION 'password_hash con formato invalido' USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    INSERT INTO usuarios (username, password_hash, rol, cliente_id)
    VALUES (p_username, p_password_hash, p_rol, p_cliente_id)
    RETURNING usuarios.id, usuarios.username, usuarios.rol, usuarios.cliente_id, usuarios.activo,
        usuarios.creado_en;
EXCEPTION
    WHEN unique_violation THEN
        IF SQLERRM LIKE '%uq_usuarios_cliente_id%' THEN
            RAISE EXCEPTION 'el cliente % ya tiene un usuario asociado', p_cliente_id USING ERRCODE = '23505';
        END IF;
        RAISE EXCEPTION 'el username % ya existe', p_username USING ERRCODE = '23505';
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'el cliente_id % no existe', p_cliente_id USING ERRCODE = '23503';
END;
$$;

-- Postgres otorga EXECUTE a PUBLIC por defecto en funciones nuevas; lo revocamos
-- explícitamente y lo volvemos a otorgar solo a app_api en 10_roles.sql.
REVOKE ALL ON FUNCTION crear_usuario(VARCHAR, VARCHAR, VARCHAR, BIGINT) FROM PUBLIC;
