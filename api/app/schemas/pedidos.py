from datetime import datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, Field

MetodoPagoEnum = Literal["tarjeta", "efectivo", "transferencia"]


class ItemCompra(BaseModel):
    producto_id: int
    cantidad: int = Field(gt=0)


class PedidoCreate(BaseModel):
    # Requerido para admin/operador (a nombre de qué cliente se crea el
    # pedido); ignorado para rol cliente, que siempre usa el cliente_id de su
    # propio token (ver routers/pedidos.py).
    cliente_id: int | None = None
    items: list[ItemCompra] = Field(min_length=1)
    metodo_pago: MetodoPagoEnum


class PedidoCreateOut(BaseModel):
    pedido_id: int
    total: Decimal
    pago_id: int
    pago_estado: str


class PedidoResumen(BaseModel):
    id: int
    cliente_id: int
    cliente: str
    estado: str
    fecha_pedido: datetime
    total: Decimal


class ItemDetalleOut(BaseModel):
    producto_id: int
    producto: str
    cantidad: int
    precio_unitario: Decimal
    subtotal: Decimal


class PagoOut(BaseModel):
    id: int
    monto: Decimal
    metodo_pago: str
    estado: str
    fecha_pago: datetime


class PedidoDetalleOut(BaseModel):
    id: int
    cliente_id: int
    cliente: str
    estado: str
    fecha_pedido: datetime
    total: Decimal
    items: list[ItemDetalleOut]
    pagos: list[PagoOut]
