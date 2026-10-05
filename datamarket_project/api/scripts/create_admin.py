"""Bootstrap: crea o actualiza el usuario admin inicial.

Uso:
    uv run scripts/create_admin.py

Lee ADMIN_USERNAME / ADMIN_PASSWORD de variables de entorno; si ADMIN_PASSWORD
no está definida, la pide por prompt interactivo (getpass). La contraseña NUNCA
se recibe como argumento de línea de comandos (quedaría en el historial del shell).

Se conecta directamente como superusuario (PG_ADMIN_DSN) porque necesita poder
actualizar un admin ya existente, algo que la función crear_usuario() no soporta
(solo inserta usuarios nuevos).
"""

import getpass
import os
import sys

import psycopg

from app.config import settings
from app.security import hash_password

ROL_ADMIN = "admin"


def leer_credenciales() -> tuple[str, str]:
    username = os.environ.get("ADMIN_USERNAME")
    if not username:
        username = input("Username del admin: ").strip()

    password = os.environ.get("ADMIN_PASSWORD")
    if not password:
        password = getpass.getpass("Password del admin: ")

    if not username:
        sys.exit("ADMIN_USERNAME no puede estar vacío")

    largo_bytes = len(password.encode("utf-8"))
    if largo_bytes < 8 or largo_bytes > 72:
        sys.exit("El password debe tener entre 8 y 72 bytes")

    return username, password


def main() -> None:
    if not settings.pg_admin_dsn:
        sys.exit("PG_ADMIN_DSN no está configurado (ver .env.example)")

    username, password = leer_credenciales()
    password_hash = hash_password(password)

    with psycopg.connect(settings.pg_admin_dsn) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT set_config('app.current_username', 'create_admin_script', true)")
            cur.execute("SELECT id FROM usuarios WHERE username = %s", (username,))
            existente = cur.fetchone()

            if existente is None:
                cur.execute(
                    "SELECT id, username, rol, activo, creado_en FROM crear_usuario(%s, %s, %s)",
                    (username, password_hash, ROL_ADMIN),
                )
                accion = "creado"
            else:
                cur.execute(
                    """
                    UPDATE usuarios
                    SET password_hash = %s, rol = %s, actualizado_en = now()
                    WHERE username = %s
                    RETURNING id, username, rol, activo, creado_en
                    """,
                    (password_hash, ROL_ADMIN, username),
                )
                accion = "actualizado"

            fila = cur.fetchone()
        conn.commit()

    id_, username_out, rol, activo, creado_en = fila
    print(f"Admin {accion}: id={id_} username={username_out} rol={rol} activo={activo} creado_en={creado_en}")


if __name__ == "__main__":
    main()
