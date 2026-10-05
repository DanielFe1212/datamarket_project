from fastapi import APIRouter, Depends, Query
from psycopg import Connection
from psycopg.rows import dict_row

from app.db import get_db
from app.dependencies import get_current_user
from app.schemas.inventario import InventarioOut

router = APIRouter(tags=["inventario"])


@router.get("/inventario", response_model=list[InventarioOut])
def listar_inventario(
    producto_id: int | None = Query(default=None),
    solo_bajo_stock: bool = Query(default=False),
    _current_user=Depends(get_current_user),
    db: Connection = Depends(get_db),
) -> list[InventarioOut]:
    condiciones: list[str] = []
    parametros: list = []
    if producto_id is not None:
        condiciones.append("i.producto_id = %s")
        parametros.append(producto_id)
    if solo_bajo_stock:
        condiciones.append("i.stock < i.stock_minimo")
    where = f"WHERE {' AND '.join(condiciones)}" if condiciones else ""

    with db.cursor(row_factory=dict_row) as cur:
        cur.execute(
            f"""
            SELECT i.producto_id, p.nombre AS producto, i.stock, i.stock_minimo, i.actualizado_en
            FROM inventario i
            JOIN productos p ON p.id = i.producto_id
            {where}
            ORDER BY p.nombre
            """,
            parametros,
        )
        filas = cur.fetchall()

    return [InventarioOut(**fila) for fila in filas]
