from datetime import datetime

from pydantic import BaseModel


class InventarioOut(BaseModel):
    producto_id: int
    producto: str
    stock: int
    stock_minimo: int
    actualizado_en: datetime
