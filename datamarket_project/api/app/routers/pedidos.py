from fastapi import APIRouter, Depends, HTTPException, status
from psycopg import Connection, errors
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from app.db import get_db
from app.dependencies import get_current_user, require_roles
from app.schemas.auth import CurrentUser
from app.schemas.pedidos import (
    ItemDetalleOut,
    PagoOut,
    PedidoCreate,
    PedidoCreateOut,
    PedidoDetalleOut,
    PedidoResumen,
)

router = APIRouter(tags=["pedidos"])


@router.post("/pedidos", response_model=PedidoCreateOut, status_code=status.HTTP_201_CREATED)
def crear_pedido(
    body: PedidoCreate,
    current_user: CurrentUser = Depends(require_roles("admin", "operador", "cliente")),
    db: Connection = Depends(get_db),
) -> PedidoCreateOut:
    # cliente: siempre compra a nombre de su propio cliente_id (del token),
    # nunca del valor que venga en el body -- evita que pida a nombre de otro.
    if current_user.rol == "cliente":
        if current_user.cliente_id is None:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="tu usuario no esta vinculado a un cliente",
            )
        cliente_id = current_user.cliente_id
    else:
        if body.cliente_id is None:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="cliente_id es requerido para admin/operador",
            )
        cliente_id = body.cliente_id

    items_jsonb = Jsonb([item.model_dump() for item in body.items])

    try:
        with db.cursor(row_factory=dict_row) as cur:
            # Atribuye la compra (y toda la auditoría en cascada que dispara
            # realizar_compra) al usuario autenticado, no a app_api.
            cur.execute("SELECT set_config('app.current_username', %s, true)", (current_user.username,))
            cur.execute(
                "SELECT * FROM realizar_compra(%s, %s, %s)",
                (cliente_id, items_jsonb, body.metodo_pago),
            )
            fila = cur.fetchone()
        db.commit()
    except errors.ForeignKeyViolation as exc:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="cliente_id no existe") from exc
    except errors.InvalidParameterValue as exc:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=exc.diag.message_primary
        ) from exc
    except errors.Error as exc:
        db.rollback()
        # ST001 = SQLSTATE propio para "stock insuficiente" (database/08_procedures.sql);
        # no es una excepción estándar de psycopg, se distingue por el código.
        if getattr(exc, "sqlstate", None) == "ST001":
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail=exc.diag.message_primary
            ) from exc
        raise

    return PedidoCreateOut(**fila)


@router.get("/pedidos", response_model=list[PedidoResumen])
def listar_pedidos(
    cliente_id: int | None = None,
    current_user: CurrentUser = Depends(get_current_user),
    db: Connection = Depends(get_db),
) -> list[PedidoResumen]:
    if current_user.rol == "cliente":
        if current_user.cliente_id is None:
            return []
        filtro_cliente_id = current_user.cliente_id
    else:
        filtro_cliente_id = cliente_id

    condiciones: list[str] = []
    parametros: list = []
    if filtro_cliente_id is not None:
        condiciones.append("p.cliente_id = %s")
        parametros.append(filtro_cliente_id)
    where = f"WHERE {' AND '.join(condiciones)}" if condiciones else ""

    with db.cursor(row_factory=dict_row) as cur:
        cur.execute(
            f"""
            SELECT p.id, p.cliente_id, c.nombre AS cliente, p.estado, p.fecha_pedido, p.total
            FROM pedidos p
            JOIN clientes c ON c.id = p.cliente_id
            {where}
            ORDER BY p.fecha_pedido DESC
            """,
            parametros,
        )
        filas = cur.fetchall()

    return [PedidoResumen(**fila) for fila in filas]


@router.get("/pedidos/{pedido_id}", response_model=PedidoDetalleOut)
def obtener_pedido(
    pedido_id: int,
    current_user: CurrentUser = Depends(get_current_user),
    db: Connection = Depends(get_db),
) -> PedidoDetalleOut:
    with db.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT p.id, p.cliente_id, c.nombre AS cliente, p.estado, p.fecha_pedido, p.total
            FROM pedidos p
            JOIN clientes c ON c.id = p.cliente_id
            WHERE p.id = %s
            """,
            (pedido_id,),
        )
        pedido = cur.fetchone()

        if pedido is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="pedido no encontrado")

        # Un cliente solo ve sus propios pedidos; 404 (no 403) para no
        # confirmar a un cliente que un pedido ajeno existe.
        if current_user.rol == "cliente" and pedido["cliente_id"] != current_user.cliente_id:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="pedido no encontrado")

        cur.execute(
            """
            SELECT d.producto_id, p.nombre AS producto, d.cantidad, d.precio_unitario, d.subtotal
            FROM detalle_pedido d
            JOIN productos p ON p.id = d.producto_id
            WHERE d.pedido_id = %s
            ORDER BY d.id
            """,
            (pedido_id,),
        )
        items = cur.fetchall()

        cur.execute(
            """
            SELECT id, monto, metodo_pago, estado, fecha_pago
            FROM pagos
            WHERE pedido_id = %s
            ORDER BY id
            """,
            (pedido_id,),
        )
        pagos = cur.fetchall()

    return PedidoDetalleOut(
        **pedido,
        items=[ItemDetalleOut(**item) for item in items],
        pagos=[PagoOut(**pago) for pago in pagos],
    )
