-- 06_views.sql
-- Vistas de negocio (Paso 9): simplifican el acceso a información agregada y
-- evitan exponer las tablas base directamente. Las vistas corren con los
-- privilegios de su dueño (postgres, quien ejecuta este script), así que un
-- rol con SELECT solo sobre la vista puede consultarla sin necesitar acceso
-- directo a las tablas subyacentes.

-- inventario_bajo: productos cuyo stock cayó debajo del mínimo definido.
-- Se amplía el ejemplo del enunciado (SELECT * FROM inventario WHERE stock <
-- stock_minimo) con el nombre de producto/categoría y las unidades que
-- faltan, para que sea directamente accionable sin otro JOIN manual.
CREATE VIEW inventario_bajo AS
SELECT
    i.id                          AS inventario_id,
    p.id                          AS producto_id,
    p.nombre                      AS producto,
    c.nombre                      AS categoria,
    i.stock,
    i.stock_minimo,
    (i.stock_minimo - i.stock)    AS unidades_faltantes
FROM inventario i
JOIN productos p ON p.id = i.producto_id
JOIN categorias c ON c.id = p.categoria_id
WHERE i.stock < i.stock_minimo;

-- resumen_ventas_periodo: ventas agregadas por día. Solo cuenta pedidos
-- 'confirmado' (un pedido 'pendiente' o 'cancelado' no es una venta). La
-- granularidad es diaria a propósito -- "por período" se resuelve agregando
-- esta vista en la consulta (p.ej. GROUP BY date_trunc('month', periodo))
-- en vez de parametrizar la vista, que en SQL estándar no acepta argumentos.
CREATE VIEW resumen_ventas_periodo AS
SELECT
    date_trunc('day', p.fecha_pedido)::date AS periodo,
    count(DISTINCT p.id)                    AS total_pedidos,
    sum(d.cantidad)                         AS unidades_vendidas,
    sum(d.subtotal)                         AS monto_total
FROM pedidos p
JOIN detalle_pedido d ON d.pedido_id = p.id
WHERE p.estado = 'confirmado'
GROUP BY date_trunc('day', p.fecha_pedido)
ORDER BY periodo DESC;

-- resumen_compras_cliente: total comprado e histórico por cliente. LEFT JOIN
-- a propósito para que los clientes sin pedidos aparezcan con 0, en vez de
-- desaparecer de la vista (útil para detectar clientes inactivos).
CREATE VIEW resumen_compras_cliente AS
SELECT
    c.id                                                           AS cliente_id,
    c.nombre                                                       AS cliente,
    c.email,
    count(DISTINCT p.id)                                           AS total_pedidos,
    coalesce(sum(p.total) FILTER (WHERE p.estado = 'confirmado'), 0) AS monto_total_comprado,
    max(p.fecha_pedido)                                            AS ultima_compra
FROM clientes c
LEFT JOIN pedidos p ON p.cliente_id = c.id
GROUP BY c.id, c.nombre, c.email
ORDER BY monto_total_comprado DESC;
