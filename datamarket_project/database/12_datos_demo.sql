-- 12_datos_demo.sql
-- Datos de demostración para poder probar la API y las vistas sin cargar nada a mano.
-- Se ejecuta automáticamente al crear el contenedor (docker-entrypoint-initdb.d), justo
-- después de 11_seed.sql, que ya trae 4 categorías, 3 clientes, 5 productos, 5 usuarios
-- y un pedido. Este script lo amplía hasta:
--
--   categorias 8 | clientes 10 | productos 20 | inventario 20 | usuarios 8
--   pedidos ~15 (confirmados + 1 pendiente + 1 cancelado) | detalle_pedido ~30 | pagos ~15
--   auditoria: se llena sola por los triggers (usuario = 'seed_demo')
--
-- NO es el volumen de rendimiento (eso es scripts/generar_volumen.sql, aparte).
-- Credenciales nuevas (SOLO DESARROLLO): cliente2 / Cliente2#2026 (Luis Pérez),
-- cliente3 / Cliente3#2026 (Marta Gómez), ex_operador / ExOperador#2026 (inactivo).
--
-- Los scripts de pruebas (tests/) crean su propia base con database/01..11; este archivo
-- se excluye allí a propósito para no alterar los conteos esperados.

-- Los triggers de auditoría toman este valor como "quién hizo el cambio".
SELECT set_config('app.current_username', 'seed_demo', false);

-- ---------------------------------------------------------------------------
-- Categorías (+4)
-- ---------------------------------------------------------------------------
INSERT INTO categorias (nombre) VALUES
    ('Deportes'),
    ('Juguetes'),
    ('Alimentos'),
    ('Belleza');

-- ---------------------------------------------------------------------------
-- Clientes (+7). 'Diego Ramírez' queda inactivo para probar ese caso.
-- ---------------------------------------------------------------------------
INSERT INTO clientes (nombre, email, telefono, direccion, activo) VALUES
    ('Carlos Rojas',     'carlos.rojas@example.com',     '3012223344', 'Calle 80 # 20-15, Bogotá',            TRUE),
    ('Sofía Herrera',    'sofia.herrera@example.com',    '3025556677', 'Carrera 43A # 1-50, Medellín',        TRUE),
    ('Andrés Molina',    'andres.molina@example.com',    '3037778899', 'Avenida 6N # 25-10, Cali',            TRUE),
    ('Valentina Cruz',   'valentina.cruz@example.com',   '3048889900', 'Calle 72 # 10-34, Bogotá',            TRUE),
    ('Diego Ramírez',    'diego.ramirez@example.com',    '3051112233', 'Carrera 15 # 85-20, Bogotá',          FALSE),
    ('Camila Ortiz',     'camila.ortiz@example.com',     '3064445566', 'Calle 30 # 65-12, Medellín',          TRUE),
    ('Julián Vargas',    'julian.vargas@example.com',    '3076667788', 'Avenida Circunvalar # 9-80, Barranquilla', TRUE);

-- ---------------------------------------------------------------------------
-- Usuarios (+3): dos clientes con login y un operador dado de baja.
-- ---------------------------------------------------------------------------
INSERT INTO usuarios (username, password_hash, rol, cliente_id, activo) VALUES
    ('cliente2',    crypt('Cliente2#2026',    gen_salt('bf', 12)), 'cliente',
        (SELECT id FROM clientes WHERE email = 'luis.perez@example.com'),  TRUE),
    ('cliente3',    crypt('Cliente3#2026',    gen_salt('bf', 12)), 'cliente',
        (SELECT id FROM clientes WHERE email = 'marta.gomez@example.com'), TRUE),
    ('ex_operador', crypt('ExOperador#2026',  gen_salt('bf', 12)), 'operador', NULL, FALSE);

-- ---------------------------------------------------------------------------
-- Productos (+15). 'Auriculares con cable' queda inactivo (descontinuado).
-- ---------------------------------------------------------------------------
INSERT INTO productos (nombre, descripcion, precio, categoria_id, activo) VALUES
    ('Smartwatch deportivo',   'Reloj con GPS y monitor de ritmo cardíaco',          349900.00, (SELECT id FROM categorias WHERE nombre = 'Electrónica'), TRUE),
    ('Teclado mecánico',       'Teclado retroiluminado switches rojos',              219900.00, (SELECT id FROM categorias WHERE nombre = 'Electrónica'), TRUE),
    ('Auriculares con cable',  'Modelo descontinuado',                                29900.00, (SELECT id FROM categorias WHERE nombre = 'Electrónica'), FALSE),
    ('Lámpara de escritorio',  'Lámpara LED regulable con puerto USB',                89900.00, (SELECT id FROM categorias WHERE nombre = 'Hogar'),       TRUE),
    ('Cafetera de goteo',      'Cafetera para 12 tazas con temporizador',            159900.00, (SELECT id FROM categorias WHERE nombre = 'Hogar'),       TRUE),
    ('Chaqueta impermeable',   'Chaqueta ligera para lluvia, unisex',                199900.00, (SELECT id FROM categorias WHERE nombre = 'Ropa'),        TRUE),
    ('Jeans clásicos',         'Jean de corte recto, algodón',                       139900.00, (SELECT id FROM categorias WHERE nombre = 'Ropa'),        TRUE),
    ('Libro "Cien años de soledad"', 'Edición conmemorativa',                         69900.00, (SELECT id FROM categorias WHERE nombre = 'Libros'),      TRUE),
    ('Libro de cocina colombiana',   'Recetas tradicionales ilustradas',              84900.00, (SELECT id FROM categorias WHERE nombre = 'Libros'),      TRUE),
    ('Balón de fútbol',        'Balón profesional talla 5',                           99900.00, (SELECT id FROM categorias WHERE nombre = 'Deportes'),    TRUE),
    ('Mat de yoga',            'Mat antideslizante de 6 mm',                          59900.00, (SELECT id FROM categorias WHERE nombre = 'Deportes'),    TRUE),
    ('Set de bloques de construcción', '500 piezas compatibles',                     119900.00, (SELECT id FROM categorias WHERE nombre = 'Juguetes'),    TRUE),
    ('Muñeca articulada',      'Muñeca con accesorios',                               74900.00, (SELECT id FROM categorias WHERE nombre = 'Juguetes'),    TRUE),
    ('Café molido 500 g',      'Café de origen, tostión media',                       28900.00, (SELECT id FROM categorias WHERE nombre = 'Alimentos'),   TRUE),
    ('Crema hidratante facial','Crema con factor de protección solar 30',             49900.00, (SELECT id FROM categorias WHERE nombre = 'Belleza'),     TRUE);

-- Inventario de los 15 productos nuevos (los 5 originales ya lo tienen en 11_seed.sql).
-- Al final del script se ajustan algunos stocks para tener casos de bajo stock y agotado.
INSERT INTO inventario (producto_id, stock, stock_minimo)
SELECT id, 40, 8
FROM productos
WHERE id NOT IN (SELECT producto_id FROM inventario);

-- ---------------------------------------------------------------------------
-- Pedidos confirmados vía realizar_compra (descuenta stock, crea detalle y pago aprobado).
-- Se usa la misma función que la API para que el resultado sea consistente.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_cliente BIGINT;
BEGIN
    -- 1) Ana Torres
    SELECT id INTO v_cliente FROM clientes WHERE email = 'ana.torres@example.com';
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Camiseta básica'), 'cantidad', 3),
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Jeans clásicos'), 'cantidad', 1)),
        'tarjeta');
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Café molido 500 g'), 'cantidad', 4)),
        'efectivo');

    -- 2) Luis Pérez
    SELECT id INTO v_cliente FROM clientes WHERE email = 'luis.perez@example.com';
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Teclado mecánico'), 'cantidad', 1),
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Lámpara de escritorio'), 'cantidad', 1)),
        'transferencia');
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Balón de fútbol'), 'cantidad', 2)),
        'tarjeta');

    -- 3) Marta Gómez
    SELECT id INTO v_cliente FROM clientes WHERE email = 'marta.gomez@example.com';
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Smartwatch deportivo'), 'cantidad', 1)),
        'tarjeta');
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Mat de yoga'), 'cantidad', 2),
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Crema hidratante facial'), 'cantidad', 2)),
        'efectivo');

    -- 4) Carlos Rojas
    SELECT id INTO v_cliente FROM clientes WHERE email = 'carlos.rojas@example.com';
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Cafetera de goteo'), 'cantidad', 1),
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Café molido 500 g'), 'cantidad', 2)),
        'tarjeta');
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Audífonos bluetooth'), 'cantidad', 1)),
        'transferencia');

    -- 5) Sofía Herrera
    SELECT id INTO v_cliente FROM clientes WHERE email = 'sofia.herrera@example.com';
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Chaqueta impermeable'), 'cantidad', 1),
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Jeans clásicos'), 'cantidad', 2)),
        'tarjeta');

    -- 6) Andrés Molina
    SELECT id INTO v_cliente FROM clientes WHERE email = 'andres.molina@example.com';
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Set de bloques de construcción'), 'cantidad', 2),
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Muñeca articulada'), 'cantidad', 1)),
        'efectivo');

    -- 7) Valentina Cruz
    SELECT id INTO v_cliente FROM clientes WHERE email = 'valentina.cruz@example.com';
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Libro "Cien años de soledad"'), 'cantidad', 1),
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Libro de cocina colombiana'), 'cantidad', 1),
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Novela "El Camino"'), 'cantidad', 1)),
        'tarjeta');

    -- 8) Camila Ortiz
    SELECT id INTO v_cliente FROM clientes WHERE email = 'camila.ortiz@example.com';
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Smartwatch deportivo'), 'cantidad', 1),
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Mat de yoga'), 'cantidad', 1)),
        'transferencia');

    -- 9) Julián Vargas
    SELECT id INTO v_cliente FROM clientes WHERE email = 'julian.vargas@example.com';
    PERFORM realizar_compra(v_cliente,
        jsonb_build_array(
            jsonb_build_object('producto_id', (SELECT id FROM productos WHERE nombre = 'Teclado mecánico'), 'cantidad', 2)),
        'tarjeta');
END;
$$;

-- ---------------------------------------------------------------------------
-- Un pedido pendiente (pago pendiente) y uno cancelado (pago rechazado), para que
-- existan todos los estados de pedidos y pagos. No descuentan stock.
-- ---------------------------------------------------------------------------
WITH p AS (
    INSERT INTO pedidos (cliente_id, estado, total)
    SELECT id, 'pendiente', 349900.00 FROM clientes WHERE email = 'carlos.rojas@example.com'
    RETURNING id
), d AS (
    INSERT INTO detalle_pedido (pedido_id, producto_id, cantidad, precio_unitario)
    SELECT p.id, pr.id, 1, pr.precio FROM p, productos pr WHERE pr.nombre = 'Smartwatch deportivo'
    RETURNING pedido_id
)
INSERT INTO pagos (pedido_id, monto, metodo_pago, estado)
SELECT id, 349900.00, 'transferencia', 'pendiente' FROM p;

WITH p AS (
    INSERT INTO pedidos (cliente_id, estado, total)
    SELECT id, 'cancelado', 199900.00 FROM clientes WHERE email = 'sofia.herrera@example.com'
    RETURNING id
), d AS (
    INSERT INTO detalle_pedido (pedido_id, producto_id, cantidad, precio_unitario)
    SELECT p.id, pr.id, 1, pr.precio FROM p, productos pr WHERE pr.nombre = 'Chaqueta impermeable'
    RETURNING pedido_id
)
INSERT INTO pagos (pedido_id, monto, metodo_pago, estado)
SELECT id, 199900.00, 'tarjeta', 'rechazado' FROM p;

-- ---------------------------------------------------------------------------
-- Reparte los pedidos en los últimos ~90 días (el pedido 1 queda "hoy") para que
-- resumen_ventas_periodo y los filtros por fecha tengan algo que mostrar.
-- ---------------------------------------------------------------------------
UPDATE pedidos
SET fecha_pedido = now() - ((id - 1) * 6 || ' days')::interval - interval '3 hours'
WHERE id > 1;

UPDATE pagos
SET fecha_pago = (SELECT fecha_pedido FROM pedidos WHERE pedidos.id = pagos.pedido_id)
WHERE pedido_id > 1;

-- ---------------------------------------------------------------------------
-- Ajustes finales de inventario para tener casos de prueba de stock:
--   - bajo stock (stock < stock_minimo): sábanas (ya viene en el seed), Café, Balón
--   - agotado (stock = 0): Muñeca articulada
-- ---------------------------------------------------------------------------
UPDATE inventario SET stock = 6 WHERE producto_id = (SELECT id FROM productos WHERE nombre = 'Café molido 500 g');
UPDATE inventario SET stock = 3 WHERE producto_id = (SELECT id FROM productos WHERE nombre = 'Balón de fútbol');
UPDATE inventario SET stock = 0 WHERE producto_id = (SELECT id FROM productos WHERE nombre = 'Muñeca articulada');

SELECT set_config('app.current_username', '', false);
