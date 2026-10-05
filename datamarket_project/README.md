# DataMarket S.A.S. — Laboratorio de base de datos

Este repositorio implementa el laboratorio descrito en `enunciado/taller_arquitecturas.pdf` (arquitectura
3-tier: cliente → API → PostgreSQL). Estado actual:

- ✅ Gestión de usuarios (esquema, roles, API, bootstrap, tests) — ver secciones de abajo.
- ✅ Modelo de datos completo: `categorias`, `clientes`, `productos`, `inventario`, `pedidos`,
  `detalle_pedido`, `pagos` (tablas, FKs, constraints, índices, seed de ejemplo).
- ✅ Backup y restauración (`scripts/backup.sh`, `scripts/restore.sh`).
- ✅ Transacciones del proceso de compra y concurrencia (`realizar_compra`, ver sección dedicada abajo).
- ✅ Auditoría extendida a las 7 tablas de negocio (antes solo cubría `usuarios`).
- ✅ Vistas de negocio: `inventario_bajo`, `resumen_ventas_periodo`, `resumen_compras_cliente`.
- ✅ API de productos/inventario/pedidos (`GET /productos`, `GET /inventario`, `POST /pedidos`,
  `GET /pedidos`, `GET /pedidos/{id}`) — ver sección dedicada abajo.
- ✅ Generación de volumen (`scripts/generar_volumen.sql`) y optimización con `EXPLAIN ANALYZE` — ver
  `docs/rendimiento.md` para la evidencia completa (3 consultas, antes/después, justificación por índice).
- ✅ Documentación: `docs/arquitectura.md`, `docs/decisiones-tecnicas.md`, `docs/diccionario-datos.md`.
- ⏳ Pendiente: funciones/procedimientos adicionales, pruebas automatizadas de todo lo anterior, reto final.

Documentación completa del proyecto: este `README.md` (cómo levantar todo, credenciales de prueba,
referencia de endpoints) + `docs/arquitectura.md` (diagrama y flujo de una request) +
`docs/decisiones-tecnicas.md` (el porqué de cada decisión) + `docs/diccionario-datos.md` (esquema completo)
+ `docs/rendimiento.md` (evidencia de `EXPLAIN ANALYZE`).

## Estructura

```
database/   scripts SQL numerados (01..11), ejecutar en orden
docker/     docker-compose.yml con PostgreSQL 16
api/        API FastAPI (gestionada con uv) + scripts/create_admin.py
scripts/    backup.sh / restore.sh (herramientas de DBA, fuera de la API)
tests/      pytest contra una base de datos separada datamarket_test
backup/     archivos .backup generados por scripts/backup.sh (ignorados por git)
```

## 1. Levantar PostgreSQL

```bash
docker compose -f docker/docker-compose.yml up -d
docker ps   # confirmar que datamarket-postgres está healthy
```

El contenedor expone PostgreSQL en el puerto **5433** del host (el 5432 se evita porque suele estar ocupado
por un PostgreSQL nativo). Si necesitas otro puerto: `POSTGRES_PORT=<puerto> docker compose ... up -d`, y
ajusta `DATABASE_URL`/`PG_ADMIN_DSN` en `api/.env`.

## 2. Esquema (automático)

Los scripts `database/01..11` se montan en `/docker-entrypoint-initdb.d`, así que la **primera vez** que el
contenedor arranca con el volumen vacío crea solo el esquema, los roles y los datos. No hay que ejecutar nada.

- `11_seed.sql`: los 5 usuarios de prueba y un catálogo mínimo (4 categorías, 3 clientes, 5 productos, 1 pedido).
- `12_datos_demo.sql`: amplía todas las tablas para probar la API sin cargar nada a mano — 8 categorías,
  10 clientes, 20 productos (1 inactivo), 8 usuarios (1 inactivo), 16 pedidos repartidos en ~90 días
  (14 confirmados, 1 pendiente, 1 cancelado) con sus detalles y pagos (aprobados, pendiente, rechazado),
  casos de bajo stock y de producto agotado, y la auditoría generada por los triggers (usuario `seed_demo`).
Para reiniciar desde cero: `docker compose -f docker/docker-compose.yml down -v` y volver a hacer `up -d`.

Para correr los tests hace falta una base separada `datamarket_test` con el mismo esquema:

```bash
psql -h localhost -p 5433 -U postgres -d postgres -c "CREATE DATABASE datamarket_test;"
for f in database/0*.sql database/10_*.sql database/11_*.sql; do
  psql -h localhost -p 5433 -U postgres -d datamarket_test -f "$f"
done
```

## 3. Levantar la API

```bash
cd api
uv sync
cp .env.example .env   # ajustar JWT_SECRET_KEY; opcionalmente la password de app_api
uv run scripts/create_admin.py   # ADMIN_USERNAME/ADMIN_PASSWORD por env o prompt interactivo
uv run uvicorn app.main:app --reload --port 8000
```

`scripts/create_admin.py` nunca recibe la contraseña como argumento de línea de comandos. Si
`ADMIN_PASSWORD` no está en el entorno, la pide de forma interactiva con `getpass` (no queda en el
historial de la shell).

## 4. Correr los tests

```bash
cd api
TEST_PG_ADMIN_DSN=postgresql://postgres:postgres@localhost:5433/datamarket_test \
TEST_APP_API_DSN=postgresql://app_api:app_api_dev_only@localhost:5433/datamarket_test \
uv run pytest ../tests -v
```

## 5. Backup y restauración

> `pg_dump`/`pg_restore` deben ser de versión **>= 16** (la del servidor). Un cliente más viejo (p.ej.
> `postgresql@14` de Homebrew) falla con `server version mismatch`. Verifica con `pg_dump --version`; si
> no coincide, instala `brew install postgresql@16` y antepón su bin al PATH solo para estos comandos:
> `PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"`.

```bash
# Backup (Paso 12). Requiere PGPASSWORD en el entorno, nunca como argumento.
PGPASSWORD=postgres ./scripts/backup.sh
# -> backup/datamarket_<timestamp>.backup

# Restauración (Paso 13). Por defecto restaura sobre datamarket_restaurada,
# sin tocar la base de desarrollo. Si no se indica archivo, usa el más reciente.
PGPASSWORD=postgres ./scripts/restore.sh
PGPASSWORD=postgres ./scripts/restore.sh backup/datamarket_20260101_120000.backup mi_base_restaurada
```

Ambos scripts leen `PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE`/`BACKUP_DIR` del entorno (con defaults iguales a
`docker/docker-compose.yml`) y fallan explícitamente si `PGPASSWORD` no está definido — la contraseña nunca
se pide como argumento (quedaría en el historial de la shell) ni se escribe en el script.

## Endpoints

| Método | Ruta                | Auth                              | Descripción |
|--------|---------------------|------------------------------------|-------------|
| POST   | `/auth/login`       | pública                            | Devuelve un JWT (30 min) si las credenciales son válidas |
| POST   | `/usuarios`         | solo `admin`                       | Crea un usuario. 201 / 409 (duplicado) / 422 (rol, password o `cliente_id` inválidos) / 403 |
| GET    | `/productos`        | cualquier rol autenticado          | Lista productos (filtros `categoria_id`, `solo_activos`) |
| GET    | `/inventario`       | cualquier rol autenticado          | Lista stock (filtros `producto_id`, `solo_bajo_stock`) |
| POST   | `/pedidos`          | `admin`, `operador`, `cliente`     | Crea un pedido vía `realizar_compra`. 201 / 400 (falta `cliente_id`, o `cliente` sin vincular) / 409 (stock insuficiente) / 422 (producto/cantidad/`cliente_id` inválidos) / 403 |
| GET    | `/pedidos`          | cualquier rol autenticado          | `cliente`: solo los propios. Resto: todos (filtro opcional `cliente_id`) |
| GET    | `/pedidos/{id}`     | cualquier rol autenticado          | Detalle con items y pagos. `cliente` pidiendo un pedido ajeno → 404 (no 403, para no confirmar su existencia) |

No existe endpoint de registro público. `POST /pedidos` con rol `cliente` **ignora** cualquier `cliente_id`
que venga en el body — siempre usa el `cliente_id` de su propio token, para que no pueda comprar a nombre
de otro cliente.

## Modelo de roles

Dos capas independientes:

- **Roles técnicos de PostgreSQL** (`db_admin`, `db_developer`, `db_analyst`, `db_operator`, `db_auditor`):
  para acceso directo a la base de datos (equipo DBA, analistas/auditores con SQL directo). La API nunca
  se conecta con estos roles.
- **Rol técnico de la API** (`app_api`): único rol de conexión del backend, con privilegios mínimos —
  `SELECT` sobre `usuarios`/catálogo/pedidos (columnas específicas donde aplica) y `EXECUTE` sobre
  `crear_usuario`/`realizar_compra`. Nunca tiene `INSERT`/`UPDATE`/`DELETE` directo sobre ninguna tabla; toda
  escritura pasa por esas dos funciones `SECURITY DEFINER`.
- **Roles de negocio** (`usuarios.rol`: `admin`, `operador`, `analista`, `auditor`, `cliente`): autorización
  fina resuelta en la API a partir del JWT.

**Vínculo usuarios↔clientes**: `usuarios.cliente_id` (nullable, `UNIQUE`, FK a `clientes.id`) conecta un
login con rol `cliente` a su fila de `clientes`. Las cuentas de staff (`admin`/`operador`/`analista`/
`auditor`) no tienen `cliente_id`. El JWT incluye `cliente_id` como claim, así la API resuelve "mis propios
pedidos" sin una consulta extra. No existe (todavía) un endpoint para crear `clientes` vía API — se asocian
con `UPDATE usuarios SET cliente_id = ...` directo (así lo hace `database/11_seed.sql` con el usuario
`cliente` de demo) o pasando `cliente_id` al crear el usuario con `POST /usuarios`.

## Credenciales de prueba (SOLO DESARROLLO, nunca usar en producción)

Creadas por `database/11_seed.sql`:

| username  | rol       | password        |
|-----------|-----------|------------------|
| admin     | admin     | `Admin#2026`     |
| operador  | operador  | `Operador#2026`  |
| analista  | analista  | `Analista#2026`  |
| auditor   | auditor   | `Auditor#2026`   |
| cliente   | cliente   | `Cliente#2026`   |

El usuario `cliente` queda vinculado (`cliente_id`) a "Ana Torres" en el seed — al loguearse como `cliente`,
`GET /pedidos` y `POST /pedidos` operan sobre los pedidos de Ana Torres.

Creados por `database/12_datos_demo.sql`: `cliente2` / `Cliente2#2026` (Luis Pérez), `cliente3` /
`Cliente3#2026` (Marta Gómez) y `ex_operador` / `ExOperador#2026` (usuario inactivo, el login debe fallar).

`app_api` se crea con password `app_api_dev_only` (ver `database/10_roles.sql` y `api/.env.example`).

## Decisiones de seguridad relevantes

- Hash único: **bcrypt** (librería `bcrypt` en Python, `pgcrypto`/`crypt()` en SQL — mismo formato,
  compatibles entre sí).
- La contraseña en texto plano nunca llega a la base de datos: la API la hashea antes de llamar a
  `crear_usuario`.
- `crear_usuario` es `SECURITY DEFINER`; `app_api` solo tiene `EXECUTE` sobre ella, no `INSERT` directo.
- El trigger de auditoría sobre `usuarios` excluye `password_hash` de `datos_anteriores`/`datos_nuevos`
  (nunca se guardan hashes en la tabla `auditoria`).
- La API fija `set_config('app.current_username', <username>, true)` (equivalente a `SET LOCAL` pero
  compatible con bind params de psycopg) antes de cada operación transaccional, para que la columna
  `auditoria.usuario` registre a la persona real (resuelta del JWT) y no siempre `app_api`.

## Proceso de compra: transacciones y concurrencia

`realizar_compra(p_cliente_id, p_items JSONB, p_metodo_pago)` (`database/08_procedures.sql`) encapsula todo
el proceso de compra (Paso 6) en una sola función: crea el pedido, inserta el detalle, descuenta inventario
y registra el pago. Es `FUNCTION` (no `PROCEDURE`) a propósito: no hace su propio `COMMIT`/`ROLLBACK`, así
que participa en la transacción de quien la llama — si cualquier paso falla (producto inexistente, cantidad
inválida, stock insuficiente), **toda** la función aborta y Postgres revierte lo que llevaba hecho (probado:
un pedido con 2 items donde el segundo falla no deja ni el pedido ni el primer item insertado).

El descuento de stock usa un `UPDATE inventario SET stock = stock - cantidad WHERE producto_id = ... AND
stock >= cantidad` atómico, en vez de "leer stock, decidir, actualizar" en pasos separados — ese patrón
clásico es el que permite sobreventa bajo concurrencia. Como `app_api` solo tiene `EXECUTE` sobre la
función (igual que con `crear_usuario`), nunca puede hacer `INSERT`/`UPDATE` directo en
`pedidos`/`detalle_pedido`/`inventario`/`pagos`.

**Concurrencia probada** con dos sesiones `psql` simultáneas comprando el último ítem en stock (stock=1):

| Nivel de aislamiento | Qué pasa | Resultado para el stock |
|---|---|---|
| `READ COMMITTED` (default) | La segunda sesión **bloquea** en el `UPDATE` hasta que la primera hace commit; al reanudar, su propio `WHERE stock >= cantidad` ya no se cumple → falla limpio con "stock insuficiente" (sin error de Postgres). | Termina en 0, nunca negativo. |
| `REPEATABLE READ` | La segunda sesión recibe `ERROR: could not serialize access due to concurrent update` (SQLSTATE `40001`) y su transacción completa se aborta — no es un mensaje de negocio, es un error de Postgres que obliga a reintentar toda la transacción. | Termina en 0. |
| `SERIALIZABLE` | Mismo resultado que `REPEATABLE READ` para este caso (conflicto de escritura sobre la misma fila). | Termina en 0. |

En los tres niveles **nunca hubo sobreventa**; la diferencia es el tipo de error y si hace falta lógica de
reintento en la capa que llama (en `READ COMMITTED` el "stock insuficiente" ya es el resultado final; en
`REPEATABLE READ`/`SERIALIZABLE` un `40001` normalmente debería reintentarse, porque puede ser un falso
conflicto). Por eso se eligió `READ COMMITTED` (el default de Postgres, mejor throughput) como nivel de
aislamiento para este endpoint: el `UPDATE ... WHERE` ya garantiza consistencia sin pagar el costo de
reintentos de `SERIALIZABLE`.

## Auditoría

El trigger de `usuarios` (`fn_auditoria_usuarios`) sigue siendo el único que excluye una columna
(`password_hash`). Las 7 tablas de negocio (`categorias`, `clientes`, `productos`, `inventario`, `pedidos`,
`detalle_pedido`, `pagos`) comparten una función genérica (`fn_auditoria`, en `database/09_triggers.sql`)
que no necesita excluir nada: registra `to_jsonb(OLD/NEW)` completo, usando `NEW.id`/`OLD.id` como
`registro_id` (todas las tablas tienen `id BIGINT` como PK). Se decidió auditar las 7 — no solo
pedidos/inventario/pagos — porque el costo marginal con la función genérica es mínimo y da trazabilidad
completa de cualquier cambio de negocio, no solo del flujo de compra.

Cada operación dentro de `realizar_compra` genera su propia fila de auditoría (INSERT en `pedidos`, UPDATE
en `inventario` por cada ítem, INSERT en `detalle_pedido`, UPDATE final en `pedidos`, INSERT en `pagos`) —
una compra con 2 ítems produce 5 filas de auditoría, todas atribuidas al mismo usuario.

`db_auditor` ahora también puede hacer `SELECT` (nunca escribir) sobre las 7 tablas de negocio, además de
`auditoria` y las columnas no sensibles de `usuarios` — para poder cruzar `auditoria.datos_nuevos` con el
estado actual de los datos.

## Vistas de negocio

`database/06_views.sql` define 3 vistas (corren con los privilegios de su dueño `postgres`, así que un rol
con `SELECT` solo sobre la vista no necesita acceso directo a las tablas base):

- **`inventario_bajo`**: productos con `stock < stock_minimo`, con nombre de producto/categoría y
  unidades faltantes (amplía el ejemplo literal del enunciado para que sea accionable).
- **`resumen_ventas_periodo`**: ventas agregadas por día (solo pedidos `estado = 'confirmado'`). La
  granularidad es diaria a propósito — para agregarlo por semana/mes se agrupa la vista en la consulta
  (`GROUP BY date_trunc('month', periodo)`), ya que una vista SQL no acepta parámetros.
- **`resumen_compras_cliente`**: total de pedidos y monto comprado por cliente, con `LEFT JOIN` para que
  los clientes sin compras aparezcan en 0 (útil para detectar clientes inactivos) en vez de desaparecer.

`db_admin`/`db_developer`/`db_analyst` las ven automáticamente (su `GRANT ... ON ALL TABLES IN SCHEMA
public` ya cubre vistas, no solo tablas base); `db_operator` y `db_auditor` tienen `GRANT SELECT` explícito
sobre las 3.

## Modelo de datos de negocio

`categorias` → `productos` (FK `categoria_id`) → `inventario` (1:1 con `productos`, FK `producto_id`
`UNIQUE`); `clientes` → `pedidos` (FK `cliente_id`) → `detalle_pedido` (FK a `pedidos` y `productos`,
`subtotal` es columna generada `cantidad * precio_unitario`) y `pagos` (FK `pedido_id`). Los FKs hacia
`categorias`/`clientes`/`productos` (desde `detalle_pedido`) no tienen `ON DELETE CASCADE` a propósito —
preservan historial y obligan a reasignar/desactivar en vez de borrar; `detalle_pedido`/`pagos`/`inventario`
sí cascadean porque no tienen sentido sin su padre (pedido o producto). `database/11_seed.sql` incluye un
catálogo pequeño y un pedido de ejemplo completo (no es el volumen para pruebas de rendimiento del Paso 4,
que se generará aparte).

## Volumen de datos y rendimiento

```bash
PGPASSWORD=postgres psql -h localhost -p 5433 -U postgres -d datamarket -f scripts/generar_volumen.sql
```

Agrega ~5.000 clientes, 200 productos y 50.000 pedidos históricos (con su detalle y pagos) sobre el seed
normal, en unos 5 segundos. No forma parte de la reconstrucción base (`01..11`) — se corre aparte, cuando
se necesitan datos suficientes para que `EXPLAIN ANALYZE` sea representativo. Detalle de cómo se generó
(y por qué así) en el propio script.

`docs/rendimiento.md` documenta la evidencia completa del Paso 8: 3 consultas reales de la API medidas con
`EXPLAIN ANALYZE` antes/después de cada índice nuevo (`idx_pedidos_cliente_fecha`,
`idx_pedidos_confirmado_fecha`, `idx_pagos_pendientes`, los dos últimos parciales), con los planes de
ejecución completos y la justificación de por qué cada uno (y por qué parcial en dos casos).
