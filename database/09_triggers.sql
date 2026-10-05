-- 09_triggers.sql
-- Trigger de auditoría sobre `usuarios`. Excluye password_hash de los JSONB
-- guardados en auditoria (nunca se guardan hashes en la auditoría).
--
-- `fn_auditoria_usuarios` es SECURITY DEFINER para poder escribir en `auditoria`
-- sin depender de que el rol que dispara el trigger tenga privilegios sobre esa
-- tabla (p.ej. un futuro UPDATE directo hecho por db_developer).
--
-- `usuario` se resuelve desde la variable de sesión `app.current_username`, que
-- la API fija con `SET LOCAL` antes de cada operación transaccional (ver
-- api/app/routers/usuarios.py). Si no está definida (p.ej. al correr scripts
-- SQL manuales o scripts/create_admin.py), cae a `session_user`.

CREATE OR REPLACE FUNCTION fn_auditoria_usuarios()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_usuario          TEXT;
    v_datos_anteriores JSONB;
    v_datos_nuevos     JSONB;
BEGIN
    v_usuario := COALESCE(NULLIF(current_setting('app.current_username', true), ''), session_user);

    IF TG_OP = 'DELETE' THEN
        v_datos_anteriores := to_jsonb(OLD) - 'password_hash';
        v_datos_nuevos := NULL;
    ELSIF TG_OP = 'UPDATE' THEN
        v_datos_anteriores := to_jsonb(OLD) - 'password_hash';
        v_datos_nuevos := to_jsonb(NEW) - 'password_hash';
    ELSE -- INSERT
        v_datos_anteriores := NULL;
        v_datos_nuevos := to_jsonb(NEW) - 'password_hash';
    END IF;

    INSERT INTO auditoria (usuario, operacion, tabla_afectada, registro_id, datos_anteriores, datos_nuevos)
    VALUES (v_usuario, TG_OP, TG_TABLE_NAME, COALESCE(NEW.id, OLD.id), v_datos_anteriores, v_datos_nuevos);

    RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION fn_auditoria_usuarios() FROM PUBLIC;

CREATE TRIGGER trg_auditoria_usuarios
AFTER INSERT OR UPDATE OR DELETE ON usuarios
FOR EACH ROW
EXECUTE FUNCTION fn_auditoria_usuarios();

-- Auditoría genérica para las tablas de negocio (sin columnas sensibles que
-- excluir, a diferencia de usuarios.password_hash). Se reutiliza la misma
-- función para las 7 tablas en vez de duplicar fn_auditoria_usuarios: todas
-- comparten la columna `id BIGINT` como PK, así que el mismo cuerpo sirve
-- para cualquiera de ellas vía TG_TABLE_NAME/NEW.id/OLD.id.
--
-- Se decidió auditar todo el modelo de negocio (no solo pedidos/pagos/
-- inventario) porque el costo de auditar categorias/clientes/productos es
-- marginal con esta función genérica, y deja trazabilidad completa de quién
-- cambió cualquier dato de negocio, no solo el flujo de compra.
CREATE OR REPLACE FUNCTION fn_auditoria()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_usuario          TEXT;
    v_datos_anteriores JSONB;
    v_datos_nuevos     JSONB;
    v_registro_id      BIGINT;
BEGIN
    v_usuario := COALESCE(NULLIF(current_setting('app.current_username', true), ''), session_user);

    IF TG_OP = 'DELETE' THEN
        v_datos_anteriores := to_jsonb(OLD);
        v_datos_nuevos := NULL;
        v_registro_id := OLD.id;
    ELSIF TG_OP = 'UPDATE' THEN
        v_datos_anteriores := to_jsonb(OLD);
        v_datos_nuevos := to_jsonb(NEW);
        v_registro_id := NEW.id;
    ELSE -- INSERT
        v_datos_anteriores := NULL;
        v_datos_nuevos := to_jsonb(NEW);
        v_registro_id := NEW.id;
    END IF;

    INSERT INTO auditoria (usuario, operacion, tabla_afectada, registro_id, datos_anteriores, datos_nuevos)
    VALUES (v_usuario, TG_OP, TG_TABLE_NAME, v_registro_id, v_datos_anteriores, v_datos_nuevos);

    RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION fn_auditoria() FROM PUBLIC;

CREATE TRIGGER trg_auditoria_categorias
AFTER INSERT OR UPDATE OR DELETE ON categorias
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_clientes
AFTER INSERT OR UPDATE OR DELETE ON clientes
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_productos
AFTER INSERT OR UPDATE OR DELETE ON productos
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_inventario
AFTER INSERT OR UPDATE OR DELETE ON inventario
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_pedidos
AFTER INSERT OR UPDATE OR DELETE ON pedidos
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_detalle_pedido
AFTER INSERT OR UPDATE OR DELETE ON detalle_pedido
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_pagos
AFTER INSERT OR UPDATE OR DELETE ON pagos
FOR EACH ROW EXECUTE FUNCTION fn_auditoria();
