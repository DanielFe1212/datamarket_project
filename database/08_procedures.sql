-- 08_procedures.sql
-- Proceso de compra como unidad transaccional (Paso 6 del enunciado):
-- crear pedido, insertar detalle, descontar inventario y registrar pago en
-- una sola llamada. Si cualquier paso falla, toda la función aborta y
-- Postgres revierte automáticamente lo que llevaba hecho (no hay COMMIT
-- parcial posible dentro de una función).
--
-- Es FUNCTION (no PROCEDURE): no hace su propio control de transacción
-- (COMMIT/ROLLBACK interno), así que participa en la transacción que abra
-- quien la llama (la API, o una sesión psql manual con BEGIN/COMMIT).
--
-- p_items es un array JSONB: [{"producto_id": 1, "cantidad": 2}, ...]
-- Se usa JSONB en vez de un tipo compuesto/array para aceptar un carrito de
-- tamaño variable sin definir un tipo SQL adicional.
CREATE OR REPLACE FUNCTION realizar_compra(
    p_cliente_id  BIGINT,
    p_items       JSONB,
    p_metodo_pago VARCHAR
)
RETURNS TABLE (
    pedido_id   BIGINT,
    total       NUMERIC,
    pago_id     BIGINT,
    pago_estado VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_pedido_id   BIGINT;
    v_pago_id     BIGINT;
    v_total       NUMERIC(12, 2) := 0;
    v_elem        JSONB;
    v_producto_id BIGINT;
    v_cantidad    INTEGER;
    v_precio      NUMERIC(12, 2);
    v_filas       INTEGER;
BEGIN
    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'el carrito no puede estar vacio' USING ERRCODE = '22023';
    END IF;

    INSERT INTO pedidos (cliente_id, estado, total)
    VALUES (p_cliente_id, 'pendiente', 0)
    RETURNING id INTO v_pedido_id;

    -- Se recorren los items ordenados por producto_id (no por el orden de
    -- llegada en el JSON): si dos compras concurrentes comparten productos,
    -- ambas transacciones piden los locks de inventario en el mismo orden
    -- global, lo que evita un deadlock cruzado (A espera a B que espera a A).
    FOR v_elem IN
        SELECT elem
        FROM jsonb_array_elements(p_items) AS elem
        ORDER BY (elem ->> 'producto_id')::BIGINT
    LOOP
        v_producto_id := (v_elem ->> 'producto_id')::BIGINT;
        v_cantidad    := (v_elem ->> 'cantidad')::INTEGER;

        IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
            RAISE EXCEPTION 'cantidad invalida para producto %', v_producto_id USING ERRCODE = '22023';
        END IF;

        SELECT precio INTO v_precio
        FROM productos
        WHERE id = v_producto_id AND activo;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'producto % no existe o no esta activo', v_producto_id USING ERRCODE = '22023';
        END IF;

        -- UPDATE atómico: el WHERE stock >= cantidad se evalúa sobre el valor
        -- vigente de la fila en el momento de ejecutar el UPDATE (tras
        -- esperar el lock de fila si otra transacción concurrente la tenía
        -- tomada), así que es seguro incluso en READ COMMITTED sin necesitar
        -- un SELECT ... FOR UPDATE explícito por separado.
        UPDATE inventario
        SET stock = stock - v_cantidad, actualizado_en = now()
        WHERE producto_id = v_producto_id AND stock >= v_cantidad;

        GET DIAGNOSTICS v_filas = ROW_COUNT;
        IF v_filas = 0 THEN
            -- SQLSTATE propio (no estándar) para que la API distinga "stock
            -- insuficiente" (409, conflicto de negocio) de datos inválidos
            -- (422) o de una FK/CHECK violation genérica.
            RAISE EXCEPTION 'stock insuficiente para producto %', v_producto_id USING ERRCODE = 'ST001';
        END IF;

        INSERT INTO detalle_pedido (pedido_id, producto_id, cantidad, precio_unitario)
        VALUES (v_pedido_id, v_producto_id, v_cantidad, v_precio);

        v_total := v_total + (v_cantidad * v_precio);
    END LOOP;

    UPDATE pedidos SET estado = 'confirmado', total = v_total WHERE id = v_pedido_id;

    -- Simplificación de laboratorio: no hay pasarela de pago real, el pago
    -- queda aprobado en el mismo paso. Un sistema real separaría la
    -- autorización del pago en su propio estado/proceso asíncrono.
    INSERT INTO pagos (pedido_id, monto, metodo_pago, estado)
    VALUES (v_pedido_id, v_total, p_metodo_pago, 'aprobado')
    RETURNING id INTO v_pago_id;

    RETURN QUERY SELECT v_pedido_id, v_total, v_pago_id, 'aprobado'::VARCHAR;
END;
$$;

REVOKE ALL ON FUNCTION realizar_compra(BIGINT, JSONB, VARCHAR) FROM PUBLIC;
