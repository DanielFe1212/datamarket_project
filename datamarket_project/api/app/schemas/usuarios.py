from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator

RolEnum = Literal["admin", "operador", "analista", "auditor", "cliente"]


class UsuarioCreate(BaseModel):
    username: str = Field(min_length=3, max_length=50)
    password: str
    rol: RolEnum
    cliente_id: int | None = None

    @field_validator("password")
    @classmethod
    def password_longitud_bcrypt(cls, value: str) -> str:
        # bcrypt solo usa los primeros 72 bytes de la contraseña; límite inferior
        # de 8 bytes es un mínimo de seguridad razonable para este laboratorio.
        largo_bytes = len(value.encode("utf-8"))
        if largo_bytes < 8 or largo_bytes > 72:
            raise ValueError("password debe tener entre 8 y 72 bytes")
        return value


class UsuarioOut(BaseModel):
    id: int
    username: str
    rol: str
    cliente_id: int | None
    activo: bool
    creado_en: datetime
