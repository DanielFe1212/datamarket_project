-- 05_indexes.sql
-- `username` ya tiene índice único implícito por uq_usuarios_username; no se duplica.

CREATE INDEX idx_usuarios_rol ON usuarios (rol);

CREATE INDEX idx_auditoria_tabla_registro ON auditoria (tabla_afectada, registro_id);
CREATE INDEX idx_auditoria_fecha ON auditoria (fecha DESC);

-- `categorias.nombre`, `clientes.email` e `inventario.producto_id` ya tienen
-- índice único implícito por sus UNIQUE de 04_constraints.sql; no se duplican.

CREATE INDEX idx_productos_categoria ON productos (categoria_id);

-- Historial de pedidos de UN cliente ordenado por fecha (GET /pedidos y
-- GET /pedidos?cliente_id=X ya hacen exactamente esto) es el patrón de
-- acceso real, no "cliente_id" o "fecha_pedido" por separado. Medido con
-- EXPLAIN ANALYZE (docs/rendimiento.md): con solo idx_pedidos_cliente, la
-- consulta hace Bitmap Heap Scan + filtro de estado post-índice + un Sort
-- aparte para el ORDER BY. El índice compuesto cubre filtro + orden en un
-- solo index scan y hace innecesario un idx_pedidos_cliente separado
-- (Postgres puede usar el prefijo cliente_id de este índice igual que usaría
-- uno simple).
CREATE INDEX idx_pedidos_cliente_fecha ON pedidos (cliente_id, fecha_pedido DESC);

-- Reportes/dashboards por fecha sin filtrar por cliente (resumen_ventas_periodo
-- ad hoc, "ventas del último mes") siguen necesitando buscar por fecha sola.
CREATE INDEX idx_pedidos_fecha ON pedidos (fecha_pedido DESC);

-- Índice parcial: "confirmado" es ~60% de los pedidos (no muy selectivo por
-- sí solo), pero junto con un rango de fechas acotado (reportes de ventas
-- recientes) sí vale la pena — y al ser parcial, el índice solo cubre el
-- subconjunto confirmado, más chico y barato de mantener que uno sobre toda
-- la tabla. Medido en docs/rendimiento.md: reduce el Execution Time de la
-- consulta de ventas de los últimos 30 días de ~3ms a bajo 1ms, y ya no
-- descarta filas después del índice (antes: "Rows Removed by Filter").
CREATE INDEX idx_pedidos_confirmado_fecha ON pedidos (fecha_pedido)
    WHERE estado = 'confirmado';

CREATE INDEX idx_detalle_pedido_pedido ON detalle_pedido (pedido_id);
CREATE INDEX idx_detalle_pedido_producto ON detalle_pedido (producto_id);

CREATE INDEX idx_pagos_pedido ON pagos (pedido_id);

-- Índice parcial: 'pendiente' es una minoría de los pagos (la mayoría queda
-- 'aprobado' de inmediato); igual que arriba, indexar solo ese subconjunto es
-- más barato que un índice sobre toda la tabla y evita el Seq Scan completo
-- que hacía esta consulta de reconciliación (ver docs/rendimiento.md).
CREATE INDEX idx_pagos_pendientes ON pagos (pedido_id) WHERE estado = 'pendiente';
