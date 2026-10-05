# Decisiones técnicas

Por qué se hizo cada cosa, no solo qué se hizo. Organizado por tema; cada sección referencia el archivo
donde vive la implementación.

## Qué vive en la base vs. qué vive en la API

Regla aplicada en todo el proyecto: **una regla que, de violarse, dejaría datos inconsistentes o inseguros
pase lo que pase en la API, vive en Postgres** (constraint, trigger o función `SECURITY DEFINER`). Lo demás
(formato de request, forma de la respuesta, qué rol puede llamar qué endpoint) vive en la API.

Ejemplos concretos:
- El stock nunca puede quedar negativo → `CHECK (stock >= 0)` + `UPDATE ... WHERE stock >= cantidad`
  atómico en `realizar_compra()` (`database/08_procedures.sql`). Si mañana alguien escribe un script que
  llama la función directo por `psql`, la regla se sigue cumpliendo — no depende de que la API valide antes.
- Un hash de contraseña nunca llega a `usuarios` sin el formato bcrypt correcto → `CHECK` de formato en
  `04_constraints.sql`, **además** de la validación en la función `crear_usuario()` y en la API. Triple
  capa a propósito (defensa en profundidad), no redundancia innecesaria.
- Qué puede hacer cada rol de negocio (admin/operador/analista/auditor/cliente) con cada endpoint → vive en
  la API (`app/dependencies.py:require_roles`), porque es una decisión de producto que puede cambiar sin
  tocar el esquema.

## Autenticación y hashing

- **bcrypt** como único algoritmo de hash (no argon2 ni otro): librería `bcrypt` en Python y
  `pgcrypto`/`crypt()` en SQL generan el mismo formato (`$2a$`/`$2b$`), compatibles entre sí — el hash de
  `database/11_seed.sql` (generado en SQL) lo puede verificar `bcrypt.checkpw` (Python) sin ningún cambio.
- **JWT (HS256, 30 min)** para autenticación de la API: es el mecanismo más simple para que endpoints como
  `POST /usuarios` exijan un rol sin mantener sesiones en el servidor. HS256 (simétrico) es suficiente
  porque hay un solo servicio que firma y verifica — no se necesita RS256/JWKS, que solo se justifica con
  múltiples servicios verificando tokens de un emisor distinto.
- La contraseña en texto plano **nunca** llega a la base: la API la hashea antes de llamar a
  `crear_usuario()`; la función solo recibe y valida el hash.

## Gestión de usuarios: `crear_usuario()` como único camino de escritura

`app_api` no tiene `INSERT` directo sobre `usuarios` — solo `EXECUTE` sobre `crear_usuario()`
(`SECURITY DEFINER`). Motivo: así la validación de rol y formato de hash ocurre siempre, sin importar qué
cliente llame la función, y la tabla no puede recibir un `INSERT` que se salte esas reglas aunque alguien
obtenga credenciales de `app_api`. El mismo patrón se repitió para `realizar_compra()`.

## Vínculo usuarios↔clientes

`usuarios` (login) y `clientes` (a nombre de quién se factura un pedido) son entidades distintas del
enunciado — un cliente de la tienda no necesariamente tiene login, y un login de staff no es un cliente.
Se agregó `usuarios.cliente_id` (nullable, `UNIQUE`, FK a `clientes.id`) para los logins con rol `cliente`,
en vez de: (a) dejarlos sin relación y exigir que cualquiera pase `cliente_id` en el body de `POST
/pedidos` (dejaría que un cliente comprara a nombre de otro), o (b) inferir el vínculo por coincidencia de
email/username (fràgil, no forzado por ninguna restricción). Con la FK, `POST /pedidos` con rol `cliente`
**ignora** cualquier `cliente_id` del body y siempre usa el del token — ver `app/routers/pedidos.py`.

## Transacciones: proceso de compra

`realizar_compra()` (`database/08_procedures.sql`) hace todo el proceso de compra (crear pedido, insertar
detalle, descontar inventario, registrar pago) en una sola función. Es `FUNCTION`, no `PROCEDURE`: una
función no hace su propio `COMMIT`/`ROLLBACK`, así que participa en la transacción de quien la llama — si
cualquier paso falla, Postgres revierte automáticamente todo lo que llevaba hecho la función, sin necesidad
de lógica de compensación manual en la API.

## Concurrencia: por qué `UPDATE ... WHERE` y no `SELECT FOR UPDATE`

El descuento de stock usa:
```sql
UPDATE inventario SET stock = stock - cantidad WHERE producto_id = X AND stock >= cantidad;
```
en vez de `SELECT stock FOR UPDATE` seguido de un `UPDATE` separado. Razón: el `WHERE stock >= cantidad` se
evalúa sobre el valor **vigente** de la fila en el momento exacto del `UPDATE` (después de esperar
cualquier lock de otra transacción concurrente), así que es seguro incluso en `READ COMMITTED` sin
necesitar un paso de bloqueo explícito separado. Es una sola sentencia, más simple y con menos
round-trips que el patrón de dos pasos.

**Nivel de aislamiento elegido: `READ COMMITTED` (el default de Postgres).** Se probó empíricamente contra
los tres niveles que pide el enunciado (dos sesiones comprando simultáneamente el último ítem en stock):

| Nivel | Qué pasa en la segunda sesión | Stock final |
|---|---|---|
| `READ COMMITTED` | Bloquea en el `UPDATE`, luego su propio `WHERE` ya no se cumple → falla limpio con "stock insuficiente" (mensaje de negocio) | 0 |
| `REPEATABLE READ` | `ERROR: could not serialize access due to concurrent update` (40001) → la transacción completa se aborta, hay que reintentarla | 0 |
| `SERIALIZABLE` | Mismo resultado que `REPEATABLE READ` para este caso | 0 |

En los tres niveles nunca hubo sobreventa. Se eligió `READ COMMITTED` porque da el mismo resultado
correcto con mejor throughput (sin el costo de abortos/reintentos de `SERIALIZABLE`) — subir el nivel de
aislamiento no agrega seguridad aquí, porque la seguridad ya la da el `UPDATE ... WHERE` atómico, no el
nivel de aislamiento. Evidencia completa (planes y tiempos reales) en el historial del proyecto; el patrón
general queda documentado arriba para poder reproducirlo.

## Auditoría

- Dos funciones de trigger: `fn_auditoria_usuarios()` (excluye `password_hash` del JSONB) y `fn_auditoria()`
  (genérica, reutilizada en las 7 tablas de negocio — todas comparten `id BIGINT` como PK, así que un solo
  cuerpo sirve para cualquiera vía `TG_TABLE_NAME`/`NEW.id`/`OLD.id`). Se separaron en dos funciones en vez
  de una sola con un `CASE` por tabla, para no acoplar la lógica de exclusión de columnas sensibles (que
  solo aplica a `usuarios`) con el caso genérico.
- Se decidió auditar las 7 tablas de negocio (no solo pedidos/inventario/pagos): con la función genérica el
  costo marginal es mínimo, y da trazabilidad completa de cualquier cambio, no solo del flujo de compra.
- **Atribución por persona real, no por `app_api`**: la API fija `set_config('app.current_username',
  <username>, true)` (equivalente a `SET LOCAL` pero compatible con bind params — `SET LOCAL` directo con
  un placeholder `%s` de psycopg falla con `syntax error at or near "$1"`, porque `SET` no acepta
  parámetros bindeados) antes de cada operación transaccional. El trigger lee esa variable con
  `current_setting('app.current_username', true)` y cae a `session_user` si no está definida (scripts SQL
  manuales, `scripts/create_admin.py`). Sin esto, `auditoria.usuario` siempre diría `app_api` y se perdería
  la trazabilidad por persona, que es el propósito del Paso 11 del enunciado.
- La carga masiva de `scripts/generar_volumen.sql` deshabilita los triggers de auditoría durante la carga:
  no es actividad de negocio real, y auditarla solo infla la tabla con ruido sintético.

## Vistas de negocio

Corren con los privilegios de su dueño (`postgres`), no de quien las consulta — así un rol con `SELECT`
solo sobre la vista no necesita acceso directo a las tablas base, que es justamente lo que pide el
enunciado ("simplificar el acceso... y limitar la exposición directa de tablas"). `resumen_ventas_periodo`
tiene granularidad diaria a propósito: una vista SQL no acepta parámetros, así que agregar "por semana/mes"
se resuelve agrupando la vista en la consulta (`GROUP BY date_trunc('month', periodo)`) en vez de crear una
vista por cada granularidad posible.

## Índices: por qué dos de los nuevos son parciales

`pedidos.estado` y `pagos.estado` tienen pocos valores con distribución desbalanceada (la mayoría
`confirmado`/`aprobado`). Un índice completo sobre esas columnas sería grande, caro de mantener en cada
escritura, y el planificador probablemente lo ignoraría para el valor mayoritario (un seq scan es más
barato que un index scan cuando el resultado es gran parte de la tabla). Indexar solo el subconjunto que
realmente se consulta con frecuencia (`pedidos` confirmados recientes, `pagos` pendientes) da un índice más
chico y que el planificador sí elige — medido en `docs/rendimiento.md` (la consulta de pagos pendientes
pasó de `Seq Scan` a `Index Scan`, la mejora más clara de las tres).

## Backup/restore sin credenciales quemadas

`scripts/backup.sh`/`restore.sh` exigen `PGPASSWORD` en el entorno y fallan explícitamente si no está —
nunca la piden como argumento (quedaría en el historial de la shell) ni la tienen hardcodeada. `restore.sh`
por defecto restaura sobre una base separada (`datamarket_restaurada`), no sobre la de desarrollo, para
poder simular un incidente/recuperación sin arriesgar los datos reales.

## Decisiones de entorno de esta máquina (no son parte del diseño del proyecto)

- El puerto 5432 está ocupado por un PostgreSQL nativo preexistente en esta máquina → el `docker-compose.yml`
  usa por defecto `${POSTGRES_PORT:-5433}` y todo el proyecto (`.env.example`, tests, scripts de backup) apunta
  al 5433; se puede cambiar con `POSTGRES_PORT`.
- `pg_dump`/`pg_restore` del PATH por defecto en esta máquina son v14 (ligados a ese Postgres nativo),
  incompatibles con el servidor v16 del proyecto → se instaló `postgresql@16` vía Homebrew sin enlazarlo
  globalmente, usando su PATH solo para los comandos de backup/restore (ver `README.md`).

Ninguna de las dos es una decisión de arquitectura del proyecto — son workarounds documentados para que el
proyecto funcione en este entorno particular sin asumir que todas las máquinas tendrán el mismo conflicto.
