from fastapi import APIRouter, Depends, Query
from psycopg import Connection
from psycopg.rows import dict_row

from app.db import get_db
from app.dependencies import get_current_user
from app.schemas.productos import ProductoOut

router = APIRouter(tags=["productos"])


@router.get("/productos", response_model=list[ProductoOut])
def listar_productos(
    categoria_id: int | None = Query(default=None),
    solo_activos: bool = Query(default=True),
    _current_user=Depends(get_current_user),
    db: Connection = Depends(get_db),
) -> list[ProductoOut]:
    condiciones: list[str] = []
    parametros: list = []
    if solo_activos:
        condiciones.append("p.activo")
    if categoria_id is not None:
        condiciones.append("p.categoria_id = %s")
        parametros.append(categoria_id)
    where = f"WHERE {' AND '.join(condiciones)}" if condiciones else ""

    with db.cursor(row_factory=dict_row) as cur:
        cur.execute(
            f"""
            SELECT p.id, p.nombre, p.descripcion, p.precio, p.categoria_id, c.nombre AS categoria, p.activo
            FROM productos p
            JOIN categorias c ON c.id = p.categoria_id
            {where}
            ORDER BY p.nombre
            """,
            parametros,
        )
        filas = cur.fetchall()

    return [ProductoOut(**fila) for fila in filas]
