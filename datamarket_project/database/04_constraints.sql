-- 04_constraints.sql
-- Restricciones de integridad para usuarios y auditoria.

ALTER TABLE usuarios
    ADD CONSTRAINT uq_usuarios_username UNIQUE (username);

ALTER TABLE usuarios
    ADD CONSTRAINT chk_usuarios_rol
    CHECK (rol IN ('admin', 'operador', 'analista', 'auditor', 'cliente'));

ALTER TABLE usuarios
    ADD CONSTRAINT chk_usuarios_username_formato
    CHECK (username ~ '^[a-zA-Z0-9_.-]{3,50}$');

-- Defensa en profundidad: el formato bcrypt también se valida en crear_usuario()
-- (07_functions.sql) antes de llegar aquí, pero el CHECK evita que cualquier otro
-- camino de escritura (p.ej. un UPDATE directo de un rol con privilegios) inserte
-- un valor que no sea un hash bcrypt válido.
ALTER TABLE usuarios
    ADD CONSTRAINT chk_usuarios_password_hash_formato
    CHECK (password_hash ~ '^\$2[aby]\$\d{2}\$.{53}$');

-- Un usuario-login se vincula a lo sumo a un cliente, y un cliente a lo sumo
-- a un usuario-login (UNIQUE en ambos sentidos de la FK).
ALTER TABLE usuarios
    ADD CONSTRAINT uq_usuarios_cliente_id UNIQUE (cliente_id);
ALTER TABLE usuarios
    ADD CONSTRAINT fk_usuarios_cliente
    FOREIGN KEY (cliente_id) REFERENCES clientes (id);

ALTER TABLE auditoria
    ADD CONSTRAINT chk_auditoria_operacion
    CHECK (operacion IN ('INSERT', 'UPDATE', 'DELETE'));

-- categorias
ALTER TABLE categorias
    ADD CONSTRAINT uq_categorias_nombre UNIQUE (nombre);

-- clientes
ALTER TABLE clientes
    ADD CONSTRAINT uq_clientes_email UNIQUE (email);
ALTER TABLE clientes
    ADD CONSTRAINT chk_clientes_email_formato
    CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');

-- productos
-- Sin ON DELETE: no se puede borrar una categoria con productos asociados
-- (hay que reasignarlos primero); evita perder la trazabilidad de precios.
ALTER TABLE productos
    ADD CONSTRAINT fk_productos_categoria
    FOREIGN KEY (categoria_id) REFERENCES categorias (id);
ALTER TABLE productos
    ADD CONSTRAINT chk_productos_precio
    CHECK (precio >= 0);

-- inventario
-- Relación 1:1 con productos (UNIQUE en producto_id); CASCADE porque un
-- registro de inventario no tiene sentido sin su producto.
ALTER TABLE inventario
    ADD CONSTRAINT uq_inventario_producto UNIQUE (producto_id);
ALTER TABLE inventario
    ADD CONSTRAINT fk_inventario_producto
    FOREIGN KEY (producto_id) REFERENCES productos (id) ON DELETE CASCADE;
ALTER TABLE inventario
    ADD CONSTRAINT chk_inventario_stock
    CHECK (stock >= 0);
ALTER TABLE inventario
    ADD CONSTRAINT chk_inventario_stock_minimo
    CHECK (stock_minimo >= 0);

-- pedidos
-- Sin ON DELETE: no se puede borrar un cliente con pedidos (preserva
-- historial); en la práctica se desactivaría (clientes.activo = false).
ALTER TABLE pedidos
    ADD CONSTRAINT fk_pedidos_cliente
    FOREIGN KEY (cliente_id) REFERENCES clientes (id);
ALTER TABLE pedidos
    ADD CONSTRAINT chk_pedidos_estado
    CHECK (estado IN ('pendiente', 'confirmado', 'cancelado'));
ALTER TABLE pedidos
    ADD CONSTRAINT chk_pedidos_total
    CHECK (total >= 0);

-- detalle_pedido
-- CASCADE en pedido_id: el detalle es parte del pedido, no existe solo.
-- Sin ON DELETE en producto_id: preserva el detalle histórico de pedidos
-- pasados aunque el producto referenciado ya no exista en catálogo.
ALTER TABLE detalle_pedido
    ADD CONSTRAINT fk_detalle_pedido_pedido
    FOREIGN KEY (pedido_id) REFERENCES pedidos (id) ON DELETE CASCADE;
ALTER TABLE detalle_pedido
    ADD CONSTRAINT fk_detalle_pedido_producto
    FOREIGN KEY (producto_id) REFERENCES productos (id);
ALTER TABLE detalle_pedido
    ADD CONSTRAINT chk_detalle_pedido_cantidad
    CHECK (cantidad > 0);
ALTER TABLE detalle_pedido
    ADD CONSTRAINT chk_detalle_pedido_precio_unitario
    CHECK (precio_unitario >= 0);

-- pagos
-- CASCADE en pedido_id: el pago es parte del pedido, no existe solo.
ALTER TABLE pagos
    ADD CONSTRAINT fk_pagos_pedido
    FOREIGN KEY (pedido_id) REFERENCES pedidos (id) ON DELETE CASCADE;
ALTER TABLE pagos
    ADD CONSTRAINT chk_pagos_monto
    CHECK (monto >= 0);
ALTER TABLE pagos
    ADD CONSTRAINT chk_pagos_metodo
    CHECK (metodo_pago IN ('tarjeta', 'efectivo', 'transferencia'));
ALTER TABLE pagos
    ADD CONSTRAINT chk_pagos_estado
    CHECK (estado IN ('pendiente', 'aprobado', 'rechazado'));
