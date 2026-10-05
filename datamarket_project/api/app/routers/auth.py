from fastapi import APIRouter, Depends, HTTPException, status
from psycopg import Connection
from psycopg.rows import dict_row

from app.db import get_db
from app.schemas.auth import LoginRequest, TokenResponse
from app.security import create_access_token, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])

CREDENCIALES_INVALIDAS = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED, detail="credenciales invalidas"
)


@router.post("/login", response_model=TokenResponse)
def login(body: LoginRequest, db: Connection = Depends(get_db)) -> TokenResponse:
    with db.cursor(row_factory=dict_row) as cur:
        cur.execute(
            "SELECT id, username, password_hash, rol, cliente_id, activo FROM usuarios WHERE username = %s",
            (body.username,),
        )
        usuario = cur.fetchone()

    if usuario is None or not usuario["activo"]:
        raise CREDENCIALES_INVALIDAS

    if not verify_password(body.password, usuario["password_hash"]):
        raise CREDENCIALES_INVALIDAS

    token = create_access_token(
        user_id=usuario["id"],
        username=usuario["username"],
        rol=usuario["rol"],
        cliente_id=usuario["cliente_id"],
    )
    return TokenResponse(access_token=token)
