-- 11_seed.sql
-- Habilita pgcrypto y crea un usuario de prueba por cada rol de aplicación.
--
-- Credenciales SOLO PARA DESARROLLO, documentadas también en README.md.
-- NUNCA usar estos valores en un entorno real.
--
--   username  | rol       | password
--   ----------|-----------|----------------
--   admin     | admin     | Admin#2026
--   operador  | operador  | Operador#2026
--   analista  | analista  | Analista#2026
--   auditor   | auditor   | Auditor#2026
--   cliente   | cliente   | Cliente#2026

CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO usuarios (username, password_hash, rol) VALUES
    ('admin',    crypt('Admin#2026',    gen_salt('bf', 12)), 'admin'),
    ('operador', crypt('Operador#2026', gen_salt('bf', 12)), 'operador'),
    ('analista', crypt('Analista#2026', gen_salt('bf', 12)), 'analista'),
    ('auditor',  crypt('Auditor#2026',  gen_salt('bf', 12)), 'auditor'),
    ('cliente',  crypt('Cliente#2026',  gen_salt('bf', 12)), 'cliente');

-- Datos de muestra del modelo de negocio (catálogo pequeño + un pedido
-- completo de ejemplo). NO es el volumen de datos para pruebas de
-- rendimiento (Paso 4/8 del enunciado) — eso se generará aparte con un
-- script dedicado y se documentará cómo, cuando se aborde ese paso.

INSERT INTO categorias (nombre) VALUES
    ('Electrónica'),
    ('Hogar'),
    ('Ropa'),
    ('Libros');

INSERT INTO clientes (nombre, email, telefono, direccion) VALUES
    ('Ana Torres',   'ana.torres@example.com',   '3001234567', 'Calle 10 # 5-20, Bogotá'),
    ('Luis Pérez',   'luis.perez@example.com',   '3109876543', 'Carrera 7 # 45-10, Medellín'),
    ('Marta Gómez',  'marta.gomez@example.com',  '3201112233', 'Avenida 3 # 12-30, Cali');

-- Vincula el usuario-login 'cliente' (rol de aplicación) con Ana Torres, para
-- poder probar de punta a punta GET/POST /pedidos autenticado como cliente.
UPDATE usuarios
SET cliente_id = (SELECT id FROM clientes WHERE email = 'ana.torres@example.com')
WHERE username = 'cliente';

INSERT INTO productos (nombre, descripcion, precio, categoria_id) VALUES
    ('Audífonos bluetooth', 'Audífonos inalámbricos con cancelación de ruido',
        189900.00, (SELECT id FROM categorias WHERE nombre = 'Electrónica')),
    ('Cargador USB-C 65W',  'Cargador rápido con cable incluido',
        79900.00,  (SELECT id FROM categorias WHERE nombre = 'Electrónica')),
    ('Juego de sábanas',    'Juego de sábanas dobles 100% algodón',
        129900.00, (SELECT id FROM categorias WHERE nombre = 'Hogar')),
    ('Camiseta básica',     'Camiseta de algodón, varias tallas',
        39900.00,  (SELECT id FROM categorias WHERE nombre = 'Ropa')),
    ('Novela "El Camino"',  'Edición de tapa blanda',
        54900.00,  (SELECT id FROM categorias WHERE nombre = 'Libros'));

-- stock_minimo intencionalmente mayor que stock en "Juego de sábanas" para
-- poder probar la futura vista inventario_bajo (Paso 9) con datos reales.
INSERT INTO inventario (producto_id, stock, stock_minimo)
SELECT id,
       CASE nombre WHEN 'Juego de sábanas' THEN 2 ELSE 50 END,
       CASE nombre WHEN 'Juego de sábanas' THEN 5 ELSE 10 END
FROM productos;

-- Un pedido de ejemplo completo (pedido + detalle + pago) para demostrar
-- la cadena de relaciones de punta a punta.
WITH nuevo_pedido AS (
    INSERT INTO pedidos (cliente_id, estado, total)
    SELECT id, 'confirmado', 269800.00 FROM clientes WHERE email = 'ana.torres@example.com'
    RETURNING id
)
INSERT INTO detalle_pedido (pedido_id, producto_id, cantidad, precio_unitario)
SELECT nuevo_pedido.id, productos.id, 1, productos.precio
FROM nuevo_pedido, productos
WHERE productos.nombre IN ('Audífonos bluetooth', 'Cargador USB-C 65W');

INSERT INTO pagos (pedido_id, monto, metodo_pago, estado)
SELECT pedidos.id, pedidos.total, 'tarjeta', 'aprobado'
FROM pedidos
JOIN clientes ON clientes.id = pedidos.cliente_id
WHERE clientes.email = 'ana.torres@example.com';
