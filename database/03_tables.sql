-- 03_tables.sql
-- Tablas del laboratorio. FK, UNIQUE y CHECK se agregan en 04_constraints.sql
-- (aquí solo columnas, tipos, PRIMARY KEY, NOT NULL y DEFAULT) para mantener
-- la separación de pasos del enunciado (Paso 3: "tablas e integridad").
-- Orden pensado para que cada CREATE TABLE pueda referenciar FKs de tablas
-- anteriores en 04_constraints.sql: categorias/clientes -> productos ->
-- inventario -> pedidos -> detalle_pedido/pagos.

-- cliente_id vincula un login con rol 'cliente' a su fila de clientes (quien
-- aparece en pedidos/pagos). Nullable: las cuentas de staff (admin/operador/
-- analista/auditor) no tienen cliente asociado. FK y UNIQUE en
-- 04_constraints.sql (clientes se crea más abajo en este mismo archivo).
CREATE TABLE usuarios (
    id              BIGSERIAL PRIMARY KEY,
    username        VARCHAR(50) NOT NULL,
    password_hash   VARCHAR(60) NOT NULL,
    rol             VARCHAR(20) NOT NULL,
    cliente_id      BIGINT,
    activo          BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE auditoria (
    id               BIGSERIAL PRIMARY KEY,
    usuario          TEXT,
    fecha            TIMESTAMPTZ NOT NULL DEFAULT now(),
    operacion        TEXT NOT NULL,
    tabla_afectada   TEXT NOT NULL,
    registro_id      BIGINT,
    datos_anteriores JSONB,
    datos_nuevos     JSONB
);

CREATE TABLE categorias (
    id         BIGSERIAL PRIMARY KEY,
    nombre     VARCHAR(100) NOT NULL,
    creado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE clientes (
    id         BIGSERIAL PRIMARY KEY,
    nombre     VARCHAR(150) NOT NULL,
    email      VARCHAR(255) NOT NULL,
    telefono   VARCHAR(30),
    direccion  TEXT,
    activo     BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE productos (
    id            BIGSERIAL PRIMARY KEY,
    nombre        VARCHAR(150) NOT NULL,
    descripcion   TEXT,
    precio        NUMERIC(12, 2) NOT NULL,
    categoria_id  BIGINT NOT NULL,
    activo        BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE inventario (
    id             BIGSERIAL PRIMARY KEY,
    producto_id    BIGINT NOT NULL,
    stock          INTEGER NOT NULL DEFAULT 0,
    stock_minimo   INTEGER NOT NULL DEFAULT 0,
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE pedidos (
    id            BIGSERIAL PRIMARY KEY,
    cliente_id    BIGINT NOT NULL,
    estado        VARCHAR(20) NOT NULL DEFAULT 'pendiente',
    fecha_pedido  TIMESTAMPTZ NOT NULL DEFAULT now(),
    total         NUMERIC(12, 2) NOT NULL DEFAULT 0
);

-- subtotal es columna generada (cantidad * precio_unitario): evita que un
-- INSERT/UPDATE deje el detalle inconsistente con sus propios cantidad/precio.
CREATE TABLE detalle_pedido (
    id               BIGSERIAL PRIMARY KEY,
    pedido_id        BIGINT NOT NULL,
    producto_id      BIGINT NOT NULL,
    cantidad         INTEGER NOT NULL,
    precio_unitario  NUMERIC(12, 2) NOT NULL,
    subtotal         NUMERIC(12, 2) GENERATED ALWAYS AS (cantidad * precio_unitario) STORED
);

CREATE TABLE pagos (
    id            BIGSERIAL PRIMARY KEY,
    pedido_id     BIGINT NOT NULL,
    monto         NUMERIC(12, 2) NOT NULL,
    metodo_pago   VARCHAR(30) NOT NULL,
    estado        VARCHAR(20) NOT NULL DEFAULT 'pendiente',
    fecha_pago    TIMESTAMPTZ NOT NULL DEFAULT now()
);
