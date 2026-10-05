# Diccionario de datos

Generado a partir de `database/03_tables.sql`, `04_constraints.sql` y `05_indexes.sql` (fuente de verdad;
si este documento y el SQL alguna vez difieren, el SQL manda). PK = `BIGSERIAL PRIMARY KEY` en todas las
tablas salvo que se indique otra cosa.

## usuarios

Credenciales de acceso a la API/BD. Separada de `clientes` (ver [[vínculo usuarios↔clientes]] en
`decisiones-tecnicas.md`).

| Columna | Tipo | Nulo | Default | Restricciones | Descripción |
|---|---|---|---|---|---|
| id | BIGINT | NO | autoincremental | PK | Identificador |
| username | VARCHAR(50) | NO | — | UNIQUE, `CHECK` formato `^[a-zA-Z0-9_.-]{3,50}$` | Nombre de login |
| password_hash | VARCHAR(60) | NO | — | `CHECK` formato bcrypt `^\$2[aby]\$\d{2}\$.{53}$` | Hash bcrypt (nunca texto plano) |
| rol | VARCHAR(20) | NO | — | `CHECK IN ('admin','operador','analista','auditor','cliente')` | Rol de negocio (autorización en la API) |
| cliente_id | BIGINT | SÍ | NULL | UNIQUE, FK → `clientes.id` | Vincula un login `cliente` con su fila de `clientes`. NULL para cuentas de staff |
| activo | BOOLEAN | NO | `TRUE` | — | Login deshabilitado sin borrar el registro |
| creado_en | TIMESTAMPTZ | NO | `now()` | — | |
| actualizado_en | TIMESTAMPTZ | NO | `now()` | — | No se actualiza automáticamente en UPDATE (sin trigger `BEFORE UPDATE`); la API la fija cuando corresponde |

Índices: `idx_usuarios_rol (rol)`, además de los índices únicos implícitos de `username` y `cliente_id`.

## auditoria

Bitácora de auditoría. Poblada únicamente por triggers (`fn_auditoria_usuarios`, `fn_auditoria`), nunca
escrita directamente por la API ni por roles de aplicación.

| Columna | Tipo | Nulo | Default | Restricciones | Descripción |
|---|---|---|---|---|---|
| id | BIGINT | NO | autoincremental | PK | |
| usuario | TEXT | SÍ | — | — | `app.current_username` (fijada por la API) o `session_user` si no está definida |
| fecha | TIMESTAMPTZ | NO | `now()` | — | |
| operacion | TEXT | NO | — | `CHECK IN ('INSERT','UPDATE','DELETE')` | |
| tabla_afectada | TEXT | NO | — | — | `TG_TABLE_NAME` del trigger que la generó |
| registro_id | BIGINT | SÍ | — | — | `id` de la fila afectada |
| datos_anteriores | JSONB | SÍ | — | — | Fila completa antes del cambio (`usuarios.password_hash` excluido); NULL en INSERT |
| datos_nuevos | JSONB | SÍ | — | — | Fila completa después del cambio (`usuarios.password_hash` excluido); NULL en DELETE |

Índices: `idx_auditoria_tabla_registro (tabla_afectada, registro_id)`, `idx_auditoria_fecha (fecha DESC)`.

## categorias

| Columna | Tipo | Nulo | Default | Restricciones | Descripción |
|---|---|---|---|---|---|
| id | BIGINT | NO | autoincremental | PK | |
| nombre | VARCHAR(100) | NO | — | UNIQUE | |
| creado_en | TIMESTAMPTZ | NO | `now()` | — | |

## clientes

| Columna | Tipo | Nulo | Default | Restricciones | Descripción |
|---|---|---|---|---|---|
| id | BIGINT | NO | autoincremental | PK | |
| nombre | VARCHAR(150) | NO | — | — | |
| email | VARCHAR(255) | NO | — | UNIQUE, `CHECK` formato `^[^@\s]+@[^@\s]+\.[^@\s]+$` | |
| telefono | VARCHAR(30) | SÍ | — | — | |
| direccion | TEXT | SÍ | — | — | |
| activo | BOOLEAN | NO | `TRUE` | — | |
| creado_en | TIMESTAMPTZ | NO | `now()` | — | |

## productos

| Columna | Tipo | Nulo | Default | Restricciones | Descripción |
|---|---|---|---|---|---|
| id | BIGINT | NO | autoincremental | PK | |
| nombre | VARCHAR(150) | NO | — | — | |
| descripcion | TEXT | SÍ | — | — | |
| precio | NUMERIC(12,2) | NO | — | `CHECK (precio >= 0)` | |
| categoria_id | BIGINT | NO | — | FK → `categorias.id` (sin `ON DELETE`) | |
| activo | BOOLEAN | NO | `TRUE` | — | |
| creado_en | TIMESTAMPTZ | NO | `now()` | — | |

Índices: `idx_productos_categoria (categoria_id)`.

## inventario

Relación 1:1 con `productos`.

| Columna | Tipo | Nulo | Default | Restricciones | Descripción |
|---|---|---|---|---|---|
| id | BIGINT | NO | autoincremental | PK | |
| producto_id | BIGINT | NO | — | UNIQUE, FK → `productos.id` `ON DELETE CASCADE` | |
| stock | INTEGER | NO | `0` | `CHECK (stock >= 0)` | Disponible actual |
| stock_minimo | INTEGER | NO | `0` | `CHECK (stock_minimo >= 0)` | Umbral para `inventario_bajo` |
| actualizado_en | TIMESTAMPTZ | NO | `now()` | — | Actualizada manualmente por `realizar_compra()` en cada descuento de stock |

## pedidos

| Columna | Tipo | Nulo | Default | Restricciones | Descripción |
|---|---|---|---|---|---|
| id | BIGINT | NO | autoincremental | PK | |
| cliente_id | BIGINT | NO | — | FK → `clientes.id` (sin `ON DELETE`) | |
| estado | VARCHAR(20) | NO | `'pendiente'` | `CHECK IN ('pendiente','confirmado','cancelado')` | |
| fecha_pedido | TIMESTAMPTZ | NO | `now()` | — | |
| total | NUMERIC(12,2) | NO | `0` | `CHECK (total >= 0)` | Recalculado por `realizar_compra()` a partir del detalle real |

Índices: `idx_pedidos_cliente_fecha (cliente_id, fecha_pedido DESC)`, `idx_pedidos_fecha (fecha_pedido
DESC)`, `idx_pedidos_confirmado_fecha (fecha_pedido) WHERE estado='confirmado'` (parcial — ver
`docs/rendimiento.md`).

## detalle_pedido

| Columna | Tipo | Nulo | Default | Restricciones | Descripción |
|---|---|---|---|---|---|
| id | BIGINT | NO | autoincremental | PK | |
| pedido_id | BIGINT | NO | — | FK → `pedidos.id` `ON DELETE CASCADE` | |
| producto_id | BIGINT | NO | — | FK → `productos.id` (sin `ON DELETE`) | Preserva el detalle histórico aunque el producto se desactive |
| cantidad | INTEGER | NO | — | `CHECK (cantidad > 0)` | |
| precio_unitario | NUMERIC(12,2) | NO | — | `CHECK (precio_unitario >= 0)` | Precio congelado al momento de la compra (no se recalcula si `productos.precio` cambia después) |
| subtotal | NUMERIC(12,2) | — | — | `GENERATED ALWAYS AS (cantidad * precio_unitario) STORED` | Columna generada, no se inserta directamente |

Índices: `idx_detalle_pedido_pedido (pedido_id)`, `idx_detalle_pedido_producto (producto_id)`.

## pagos

| Columna | Tipo | Nulo | Default | Restricciones | Descripción |
|---|---|---|---|---|---|
| id | BIGINT | NO | autoincremental | PK | |
| pedido_id | BIGINT | NO | — | FK → `pedidos.id` `ON DELETE CASCADE` | Un pedido puede tener más de un pago (no hay UNIQUE); `realizar_compra()` inserta exactamente uno por compra |
| monto | NUMERIC(12,2) | NO | — | `CHECK (monto >= 0)` | |
| metodo_pago | VARCHAR(30) | NO | — | `CHECK IN ('tarjeta','efectivo','transferencia')` | |
| estado | VARCHAR(20) | NO | `'pendiente'` | `CHECK IN ('pendiente','aprobado','rechazado')` | |
| fecha_pago | TIMESTAMPTZ | NO | `now()` | — | |

Índices: `idx_pagos_pedido (pedido_id)`, `idx_pagos_pendientes (pedido_id) WHERE estado='pendiente'`
(parcial — ver `docs/rendimiento.md`).

## Vistas (no son tablas, pero forman parte del esquema consultable)

| Vista | Definición | Descripción |
|---|---|---|
| `inventario_bajo` | `inventario` ⋈ `productos` ⋈ `categorias` WHERE `stock < stock_minimo` | Productos a reabastecer |
| `resumen_ventas_periodo` | `pedidos` ⋈ `detalle_pedido`, agregado por día, solo `estado='confirmado'` | Ventas diarias |
| `resumen_compras_cliente` | `clientes` ⟕ `pedidos`, agregado por cliente | Total comprado e histórico por cliente, incluye clientes sin compras |

## Funciones `SECURITY DEFINER`

| Función | Firma | Descripción |
|---|---|---|
| `crear_usuario` | `(p_username VARCHAR, p_password_hash VARCHAR, p_rol VARCHAR, p_cliente_id BIGINT DEFAULT NULL)` | Único camino de escritura hacia `usuarios` para `app_api` |
| `realizar_compra` | `(p_cliente_id BIGINT, p_items JSONB, p_metodo_pago VARCHAR)` | Proceso de compra completo (pedido + detalle + inventario + pago) en una transacción |
| `fn_auditoria_usuarios` / `fn_auditoria` | trigger functions | Pueblan `auditoria`; `fn_auditoria_usuarios` excluye `password_hash`, `fn_auditoria` es genérica para las 7 tablas de negocio |
