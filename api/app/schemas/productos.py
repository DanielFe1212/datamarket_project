from decimal import Decimal

from pydantic import BaseModel


class ProductoOut(BaseModel):
    id: int
    nombre: str
    descripcion: str | None
    precio: Decimal
    categoria_id: int
    categoria: str
    activo: bool
