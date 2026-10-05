from fastapi import APIRouter, Depends, HTTPException, status
from psycopg import Connection, errors
from psycopg.rows import dict_row

from app.db import get_db
from app.dependencies import require_admin
from app.schemas.auth import CurrentUser
from app.schemas.usuarios import UsuarioCreate, UsuarioOut
from app.security import hash_password

router = APIRouter(tags=["usuarios"])


@router.post("/usuarios", response_model=UsuarioOut, status_code=status.HTTP_201_CREATED)
def crear_usuario(
    body: UsuarioCreate,
    admin: CurrentUser = Depends(require_admin),
    db: Connection = Depends(get_db),
) -> UsuarioOut:
    password_hash = hash_password(body.password)

    try:
        with db.cursor(row_factory=dict_row) as cur:
            # Atribuye la operación (y el registro de auditoría disparado por el
            # trigger de usuarios) al admin autenticado, no al rol técnico app_api.
            # set_config(..., true) equivale a SET LOCAL pero sí acepta bind params.
            cur.execute("SELECT set_config('app.current_username', %s, true)", (admin.username,))
            cur.execute(
                "SELECT * FROM crear_usuario(%s, %s, %s, %s)",
                (body.username, password_hash, body.rol, body.cliente_id),
            )
            fila = cur.fetchone()
        db.commit()
    except errors.UniqueViolation as exc:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=exc.diag.message_primary) from exc
    except (errors.InvalidParameterValue, errors.ForeignKeyViolation) as exc:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=exc.diag.message_primary
        ) from exc

    return UsuarioOut(**fila)
