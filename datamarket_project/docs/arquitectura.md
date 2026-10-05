# Arquitectura

## Vista general (3 capas, como pide el enunciado)

```
CLIENTE / POSTMAN
        |
        | HTTP + JWT
        v
API (FastAPI, api/)
        |
        | SQL (psycopg3, rol app_api)
        v
POSTGRESQL 16 (docker/)
        |
        +-- Datos        (database/03_tables.sql, 04_constraints.sql)
        +-- Seguridad     (database/10_roles.sql: 5 roles técnicos + app_api)
        +-- Auditoría     (database/09_triggers.sql)
        +-- Rendimiento   (database/05_indexes.sql, docs/rendimiento.md)
        +-- Backup        (scripts/backup.sh, scripts/restore.sh)
```

Presentación = Postman/cualquier cliente HTTP. Lógica de negocio = API FastAPI **y** las funciones
`SECURITY DEFINER` de Postgres (`crear_usuario`, `realizar_compra`) — la reglas que deben garantizarse pase
lo que pase (stock nunca negativo, hash nunca en texto plano, auditoría completa) viven en la base, no solo
en la API; ver `docs/decisiones-tecnicas.md` para la justificación de qué va en cada capa.

## Componentes

- **`docker/docker-compose.yml`** — PostgreSQL 16, base `datamarket`, puerto configurable
  (`${POSTGRES_PORT:-5433}`, ver nota de conflicto de puerto en el `README`).
- **`database/`** — 11 scripts SQL numerados, ejecutables en orden desde cero (`01_database.sql` →
  `11_seed.sql`). Es la única fuente de verdad del esquema; `docs/diccionario-datos.md` se deriva de ahí.
- **`api/`** — FastAPI (gestionada con `uv`), un único rol de conexión (`app_api`, privilegios mínimos).
  Estructura: `app/main.py` (registro de routers), `app/routers/` (endpoints), `app/schemas/` (Pydantic),
  `app/dependencies.py` (auth/autorización), `app/security.py` (bcrypt + JWT), `app/db.py` (pool psycopg).
- **`scripts/`** — herramientas de DBA fuera de la app: `backup.sh`/`restore.sh` (pg_dump/pg_restore) y
  `generar_volumen.sql` (datos sintéticos para pruebas de rendimiento). Separado de `api/scripts/`
  (`create_admin.py`, que es bootstrap de la aplicación, no de la base).
- **`tests/`** — pytest, pendiente de ampliar al final (ver estado del proyecto en el `README`).

## Flujo de una request típica: `POST /pedidos`

```
1. Cliente envía POST /pedidos con JWT (Authorization: Bearer ...) + {items, metodo_pago[, cliente_id]}
2. FastAPI decodifica el JWT (app/dependencies.py:get_current_user) -> CurrentUser{user_id, rol, cliente_id}
3. require_roles("admin","operador","cliente") valida el rol -> 403 si no corresponde
4. El router resuelve el cliente_id real:
     - rol=cliente  -> siempre current_user.cliente_id (ignora el del body)
     - rol=admin/operador -> el que venga en el body (400 si falta)
5. set_config('app.current_username', ...) sobre la conexión -> atribución de auditoría
6. SELECT * FROM realizar_compra(cliente_id, items::jsonb, metodo_pago)
     - dentro de Postgres: INSERT pedido, UPDATE inventario (atómico, WHERE stock >= cantidad),
       INSERT detalle_pedido (uno por item), UPDATE pedido.total, INSERT pago
     - cada INSERT/UPDATE dispara fn_auditoria() -> fila nueva en auditoria
7. Éxito -> commit, 201 con {pedido_id, total, pago_id, pago_estado}
   Error  -> rollback completo (nada parcial), se mapea a 409/422/400 según el caso
```

La API nunca hace `INSERT`/`UPDATE` directo sobre `pedidos`/`detalle_pedido`/`inventario`/`pagos`: todo pasa
por `realizar_compra()`, que corre `SECURITY DEFINER`. `app_api` solo tiene `EXECUTE` sobre esa función (y
sobre `crear_usuario`) más `SELECT` para los endpoints de consulta — nunca privilegios de escritura directos
(ver `database/10_roles.sql`).

## Modelo de roles (dos capas + el rol de negocio)

```
                    ┌─────────────────────────────────────────┐
                    │          Roles técnicos de Postgres       │
                    │   db_admin · db_developer · db_analyst    │
                    │        db_operator · db_auditor           │
                    │   (acceso directo a la BD, NOLOGIN salvo   │
                    │    que se les asigne password/LOGIN aparte;│
                    │    la API NUNCA se conecta con estos)      │
                    └─────────────────────────────────────────┘

                    ┌─────────────────────────────────────────┐
                    │              app_api (LOGIN)              │
                    │   único rol de conexión del backend.      │
                    │   SELECT de columnas puntuales + EXECUTE  │
                    │   sobre crear_usuario()/realizar_compra() │
                    │   Nunca INSERT/UPDATE/DELETE directo.     │
                    └─────────────────────────────────────────┘

                    ┌─────────────────────────────────────────┐
                    │     usuarios.rol (dato, no rol de BD)     │
                    │  admin · operador · analista · auditor ·  │
                    │  cliente — autorización fina resuelta en  │
                    │  la API a partir del JWT (require_roles)  │
                    └─────────────────────────────────────────┘
```

Por qué dos capas y no una: los roles técnicos sirven para acceso **directo** a la base (un DBA conectado
con `psql`, un analista corriendo SQL ad hoc); el rol de negocio sirve para autorización **dentro de la
API**, que siempre se conecta con el mismo `app_api` sin importar quién esté detrás del JWT. Mezclarlos
(hacer que la API cambie de rol de Postgres según quién llama) sería mucho más complejo de implementar
(pooling de conexiones por rol, `SET ROLE` por request) sin aportar seguridad real, porque de todas formas
es la API la que decide qué query ejecutar.

## Entorno de desarrollo

```bash
docker compose -f docker/docker-compose.yml up -d   # PostgreSQL 16
# ejecutar database/01..11 en orden
cd api && uv sync && uv run scripts/create_admin.py && uv run uvicorn app.main:app --reload
```

Detalle completo, credenciales de prueba y el workaround de puerto para esta máquina en el `README.md` de
la raíz.
