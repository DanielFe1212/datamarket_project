-- generar_volumen.sql
-- Genera datos de volumen para pruebas de rendimiento (Paso 4/8 del
-- enunciado). NO forma parte de la reconstrucción base (database/01..11);
-- se corre aparte, a mano, sobre una base ya inicializada con el seed normal:
--
--   psql -h localhost -p 5433 -U postgres -d datamarket -f scripts/generar_volumen.sql
--
-- Cómo se genera (para la documentación pedida por el enunciado):
--   - 5.000 clientes y 200 productos sintéticos adicionales, con nombres/
--     emails claramente marcados como "Demo" para poder limpiarlos después
--     si hace falta (DELETE ... WHERE email LIKE 'cliente_demo_%').
--   - 50.000 pedidos históricos repartidos aleatoriamente en los últimos 365
--     días, cada uno con 1-4 líneas de detalle sobre productos aleatorios
--     (reales + demo) y, si el pedido quedó "confirmado", un pago con estado
--     ponderado (90% aprobado, 7% pendiente, 3% rechazado) para que haya una
--     minoría real que buscar en la consulta de "pagos pendientes".
--   - Se arma con un bloque PL/pgSQL (no con INSERT...SELECT + ORDER BY
--     random() por fila): elegir un cliente/producto aleatorio así sería
--     O(n_pedidos * n_clientes log n_clientes) porque cada fila dispararía
--     un sort completo de la tabla. En vez de eso se cargan los ids en un
--     array una sola vez y se indexa aleatoriamente (O(1) por fila).
--   - Los triggers de auditoría se deshabilitan durante la carga: no tiene
--     sentido auditar datos sintéticos de prueba (no es actividad de
--     negocio real) y evita inflar `auditoria` con cientos de miles de filas
--     de ruido. Se reactivan al final.
--   - Termina con ANALYZE para que el planificador tenga estadísticas
--     actualizadas antes de medir con EXPLAIN ANALYZE (si no, puede seguir
--     eligiendo seq scan por estadísticas viejas aunque haya índices útiles).

\timing on

ALTER TABLE clientes DISABLE TRIGGER trg_auditoria_clientes;
ALTER TABLE productos DISABLE TRIGGER trg_auditoria_productos;
ALTER TABLE inventario DISABLE TRIGGER trg_auditoria_inventario;
ALTER TABLE pedidos DISABLE TRIGGER trg_auditoria_pedidos;
ALTER TABLE detalle_pedido DISABLE TRIGGER trg_auditoria_detalle_pedido;
ALTER TABLE pagos DISABLE TRIGGER trg_auditoria_pagos;

INSERT INTO clientes (nombre, email, telefono, direccion)
SELECT
    'Cliente Demo ' || g,
    'cliente_demo_' || g || '@example.com',
    '300' || lpad((g % 10000000)::text, 7, '0'),
    'Direccion demo ' || g
FROM generate_series(1, 5000) AS g;

INSERT INTO productos (nombre, descripcion, precio, categoria_id)
SELECT
    'Producto Demo ' || g,
    'Descripcion de producto demo ' || g,
    (random() * 490000 + 10000)::numeric(12, 2),
    (SELECT id FROM categorias ORDER BY random() LIMIT 1)
FROM generate_series(1, 200) AS g;

INSERT INTO inventario (producto_id, stock, stock_minimo)
SELECT p.id, (random() * 200)::int, 10
FROM productos p
LEFT JOIN inventario i ON i.producto_id = p.id
WHERE i.id IS NULL;

DO $$
DECLARE
    v_cliente_ids  BIGINT[];
    v_producto_ids BIGINT[];
    v_precios      NUMERIC(12, 2)[];
    v_n_clientes   INT;
    v_n_productos  INT;
    v_pedido_id    BIGINT;
    v_cliente_id   BIGINT;
    v_estado       VARCHAR(20);
    v_fecha        TIMESTAMPTZ;
    v_n_items      INT;
    v_total        NUMERIC(12, 2);
    v_idx          INT;
    v_producto_id  BIGINT;
    v_precio       NUMERIC(12, 2);
    v_cantidad     INT;
    v_estado_pago  VARCHAR(20);
    v_roll         NUMERIC;
    i              INT;
    j              INT;
BEGIN
    SELECT array_agg(id) INTO v_cliente_ids FROM clientes;
    SELECT array_agg(id), array_agg(precio) INTO v_producto_ids, v_precios FROM productos;
    v_n_clientes := array_length(v_cliente_ids, 1);
    v_n_productos := array_length(v_producto_ids, 1);

    FOR i IN 1..50000 LOOP
        v_cliente_id := v_cliente_ids[1 + floor(random() * v_n_clientes)::int];
        v_estado := (ARRAY['confirmado', 'confirmado', 'confirmado', 'pendiente', 'cancelado'])
            [1 + floor(random() * 5)::int];
        v_fecha := now() - (random() * interval '365 days');
        v_n_items := 1 + floor(random() * 4)::int;
        v_total := 0;

        INSERT INTO pedidos (cliente_id, estado, fecha_pedido, total)
        VALUES (v_cliente_id, v_estado, v_fecha, 0)
        RETURNING id INTO v_pedido_id;

        FOR j IN 1..v_n_items LOOP
            v_idx := 1 + floor(random() * v_n_productos)::int;
            v_producto_id := v_producto_ids[v_idx];
            v_precio := v_precios[v_idx];
            v_cantidad := 1 + floor(random() * 5)::int;

            INSERT INTO detalle_pedido (pedido_id, producto_id, cantidad, precio_unitario)
            VALUES (v_pedido_id, v_producto_id, v_cantidad, v_precio);

            v_total := v_total + (v_cantidad * v_precio);
        END LOOP;

        UPDATE pedidos SET total = v_total WHERE id = v_pedido_id;

        IF v_estado = 'confirmado' THEN
            v_roll := random();
            v_estado_pago := CASE
                WHEN v_roll < 0.90 THEN 'aprobado'
                WHEN v_roll < 0.97 THEN 'pendiente'
                ELSE 'rechazado'
            END;

            INSERT INTO pagos (pedido_id, monto, metodo_pago, estado, fecha_pago)
            VALUES (
                v_pedido_id, v_total,
                (ARRAY['tarjeta', 'efectivo', 'transferencia'])[1 + floor(random() * 3)::int],
                v_estado_pago, v_fecha
            );
        END IF;
    END LOOP;
END $$;

ALTER TABLE clientes ENABLE TRIGGER trg_auditoria_clientes;
ALTER TABLE productos ENABLE TRIGGER trg_auditoria_productos;
ALTER TABLE inventario ENABLE TRIGGER trg_auditoria_inventario;
ALTER TABLE pedidos ENABLE TRIGGER trg_auditoria_pedidos;
ALTER TABLE detalle_pedido ENABLE TRIGGER trg_auditoria_detalle_pedido;
ALTER TABLE pagos ENABLE TRIGGER trg_auditoria_pagos;

ANALYZE clientes;
ANALYZE productos;
ANALYZE inventario;
ANALYZE pedidos;
ANALYZE detalle_pedido;
ANALYZE pagos;

SELECT 'clientes' AS tabla, count(*) FROM clientes
UNION ALL SELECT 'productos', count(*) FROM productos
UNION ALL SELECT 'pedidos', count(*) FROM pedidos
UNION ALL SELECT 'detalle_pedido', count(*) FROM detalle_pedido
UNION ALL SELECT 'pagos', count(*) FROM pagos;
