# Rendimiento: generación de volumen y EXPLAIN ANALYZE

Paso 4 y Paso 8 del enunciado. Evidencia real, medida contra datos generados con
`scripts/generar_volumen.sql` sobre PostgreSQL 16 en Docker (no estimaciones).

## Cómo se generó el volumen

`scripts/generar_volumen.sql` (documentado también en el propio archivo) agrega, sobre el seed normal:

- 5.000 clientes y 200 productos sintéticos adicionales.
- 50.000 pedidos históricos repartidos aleatoriamente en los últimos 365 días, cada uno con 1-4 líneas de
  detalle sobre productos aleatorios y (si quedó `confirmado`) un pago con estado ponderado (90%
  `aprobado`, 7% `pendiente`, 3% `rechazado`).

Se eligió un bloque PL/pgSQL con arrays de ids precargados (no `INSERT ... SELECT ... ORDER BY random()
LIMIT 1` por fila, que sería O(n_pedidos × n_clientes log n_clientes)) y con los triggers de auditoría
deshabilitados durante la carga (no tiene sentido auditar datos sintéticos, y evita inflar `auditoria` con
ruido). Tiempo real medido con `\timing on`: **4.76 segundos** para las 50.000 filas de `pedidos` (más
124.951 de `detalle_pedido` y 29.935 de `pagos`, generadas en el mismo bloque).

```
 tabla          | count
----------------+--------
 productos      |    205
 clientes       |   5003
 pagos          |  29935
 pedidos        |  50001
 detalle_pedido | 124951
```

Termina con `ANALYZE` sobre las tablas tocadas, para que el planificador tenga estadísticas frescas antes
de medir — sin esto, el optimizador puede seguir eligiendo un plan viejo (seq scan) por desconocer la
nueva cardinalidad, aunque ya exista un índice útil.

## Consultas medidas

Se eligieron 3 consultas que reflejan patrones de acceso reales de la API (no consultas inventadas para la
demo): el historial de pedidos que usa `GET /pedidos`, un reporte de ventas recientes, y una consulta de
reconciliación de pagos pendientes.

### Query A — Historial de pedidos confirmados de un cliente (GET /pedidos)

```sql
SELECT * FROM pedidos
WHERE cliente_id = 1 AND estado = 'confirmado'
ORDER BY fecha_pedido DESC;
```

**Antes** (solo `idx_pedidos_cliente(cliente_id)` + `idx_pedidos_fecha(fecha_pedido DESC)` por separado):

```
Sort  (actual time=0.174..0.175 rows=5 loops=1)
  Sort Key: fecha_pedido DESC
  ->  Bitmap Heap Scan on pedidos  (actual time=0.033..0.134 rows=5 loops=1)
        Recheck Cond: (cliente_id = 1)
        Filter: estado = 'confirmado'
        Rows Removed by Filter: 7
        ->  Bitmap Index Scan on idx_pedidos_cliente  (actual time=0.023..0.024 rows=12 loops=1)
Execution Time: 0.224 ms
```

**Después** (`idx_pedidos_cliente_fecha(cliente_id, fecha_pedido DESC)`, reemplaza a `idx_pedidos_cliente`):

```
Sort  (actual time=0.082..0.083 rows=5 loops=1)
  ->  Bitmap Heap Scan on pedidos  (actual time=0.026..0.072 rows=5 loops=1)
        Recheck Cond: (cliente_id = 1)
        Filter: estado = 'confirmado'
        ->  Bitmap Index Scan on idx_pedidos_cliente_fecha  (actual time=0.020..0.020 rows=12 loops=1)
Execution Time: 0.107 ms
```

**Resultado:** ~2x más rápido (0.224ms → 0.107ms), pero **no** se eliminó el `Sort` — con el volumen
generado, el cliente con más pedidos tiene solo ~23 (50.000 pedidos / 5.003 clientes), así que Postgres
sigue prefiriendo un `Bitmap Heap Scan` + `Sort` en vez de un `Index Scan` ordenado directo sobre un
resultado tan chico. El índice compuesto igual vale la pena: reemplaza a `idx_pedidos_cliente` sin perder
nada (el prefijo `cliente_id` sirve para cualquier consulta que antes usara el índice simple) y sería
determinante con más pedidos por cliente.

### Query B — Ventas confirmadas de los últimos 30 días (reporte)

```sql
SELECT * FROM pedidos
WHERE estado = 'confirmado' AND fecha_pedido >= now() - interval '30 days';
```

**Antes** (solo `idx_pedidos_fecha(fecha_pedido DESC)`, sin índice sobre `estado`):

```
Bitmap Heap Scan on pedidos  (actual time=0.740..2.955 rows=2418 loops=1)
  Recheck Cond: (fecha_pedido >= now() - '30 days')
  Filter: estado = 'confirmado'
  Rows Removed by Filter: 1609
  ->  Bitmap Index Scan on idx_pedidos_fecha  (actual time=0.577..0.577 rows=4109 loops=1)
Execution Time: 3.072 ms
```

**Después** (índice parcial `idx_pedidos_confirmado_fecha(fecha_pedido) WHERE estado = 'confirmado'`):

```
Bitmap Heap Scan on pedidos  (actual time=0.249..1.476 rows=2418 loops=1)
  Recheck Cond: (fecha_pedido >= now() - '30 days' AND estado = 'confirmado')
  ->  Bitmap Index Scan on idx_pedidos_confirmado_fecha  (actual time=0.183..0.183 rows=2418 loops=1)
Execution Time: 1.552 ms
```

**Resultado:** ~2x más rápido (3.072ms → 1.552ms) y desaparece el `Rows Removed by Filter: 1609` — antes el
índice por fecha traía de más (4.109 filas) y Postgres descartaba las no confirmadas después; el índice
parcial ya solo contiene confirmados, así que el índice y el resultado final coinciden. `estado =
'confirmado'` solo no es muy selectivo (~60% de los pedidos), por eso no se justificaba un índice sobre
`estado` solo — combinado con el rango de fechas sí.

### Query C — Pagos pendientes de reconciliar

```sql
SELECT * FROM pagos WHERE estado = 'pendiente';
```

**Antes** (sin ningún índice sobre `pagos.estado`):

```
Seq Scan on pagos  (actual time=0.009..2.302 rows=2129 loops=1)
  Filter: estado = 'pendiente'
  Rows Removed by Filter: 27806
Execution Time: 2.367 ms
```

**Después** (índice parcial `idx_pagos_pendientes(pedido_id) WHERE estado = 'pendiente'`):

```
Index Scan using idx_pagos_pendientes on pagos  (actual time=0.021..0.953 rows=2129 loops=1)
Execution Time: 1.012 ms
```

**Resultado:** ~2.3x más rápido (2.367ms → 1.012ms) y de `Seq Scan` (recorre las 29.935 filas) a `Index
Scan` (solo toca las 2.129 `pendiente`). Esta es la mejora más clara de las tres, y la que más escala: el
`Seq Scan` crece con el tamaño total de `pagos`, el índice parcial solo con el tamaño del subconjunto
`pendiente`, que en este negocio siempre debería ser una minoría.

## Por qué índices parciales (no uno completo sobre `estado`)

`pedidos.estado` y `pagos.estado` tienen 3-5 valores posibles con una distribución desbalanceada (la
mayoría `confirmado`/`aprobado`). Un índice completo sobre la columna `estado` sería grande, caro de
mantener en cada INSERT/UPDATE, y el planificador probablemente lo ignoraría igual para el valor mayoritario
(un seq scan es más barato que un index scan cuando el resultado es gran parte de la tabla). Indexar solo el
subconjunto que realmente se consulta con frecuencia (`confirmado` reciente, `pendiente`) da un índice más
chico, más barato de mantener, y que el planificador sí elige.

## Índices añadidos a `database/05_indexes.sql`

| Índice | Reemplaza/complementa | Justificación |
|---|---|---|
| `idx_pedidos_cliente_fecha (cliente_id, fecha_pedido DESC)` | `idx_pedidos_cliente` (eliminado) | Cubre el patrón real de `GET /pedidos` (filtro por cliente + orden por fecha) en un solo índice |
| `idx_pedidos_confirmado_fecha (fecha_pedido) WHERE estado='confirmado'` | nuevo | Reportes de ventas recientes; parcial porque `estado` solo no es selectivo |
| `idx_pagos_pendientes (pedido_id) WHERE estado='pendiente'` | nuevo | Reconciliación de pagos; de Seq Scan a Index Scan, la mejora más clara de las tres |

`idx_pedidos_fecha (fecha_pedido DESC)` se mantiene (sin filtro de estado) para reportes que no filtran por
`confirmado` (p.ej. todos los pedidos recientes sin importar estado).
