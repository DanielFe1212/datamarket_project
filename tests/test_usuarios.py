def test_crear_usuario_como_admin_devuelve_201(client, admin_token):
    resp = client.post(
        "/usuarios",
        json={"username": "nuevo_cliente", "password": "ClavePrueba1", "rol": "cliente"},
        headers={"Authorization": f"Bearer {admin_token}"},
    )

    assert resp.status_code == 201
    body = resp.json()
    assert body["username"] == "nuevo_cliente"
    assert body["rol"] == "cliente"
    assert "password_hash" not in body
    assert "password" not in body


def test_crear_usuario_como_operador_devuelve_403(client, operador_token):
    resp = client.post(
        "/usuarios",
        json={"username": "no_deberia_crearse", "password": "ClavePrueba1", "rol": "cliente"},
        headers={"Authorization": f"Bearer {operador_token}"},
    )

    assert resp.status_code == 403


def test_crear_usuario_username_duplicado_devuelve_409(client, admin_token):
    payload = {"username": "duplicado", "password": "ClavePrueba1", "rol": "cliente"}
    headers = {"Authorization": f"Bearer {admin_token}"}

    primero = client.post("/usuarios", json=payload, headers=headers)
    assert primero.status_code == 201

    segundo = client.post("/usuarios", json=payload, headers=headers)
    assert segundo.status_code == 409


def test_login_exitoso_usuario_recien_creado(client, admin_token):
    crear = client.post(
        "/usuarios",
        json={"username": "login_nuevo", "password": "ClavePrueba1", "rol": "analista"},
        headers={"Authorization": f"Bearer {admin_token}"},
    )
    assert crear.status_code == 201

    login = client.post("/auth/login", json={"username": "login_nuevo", "password": "ClavePrueba1"})
    assert login.status_code == 200

    body = login.json()
    assert body["token_type"] == "bearer"

    import jwt as pyjwt

    from app.config import settings

    claims = pyjwt.decode(body["access_token"], settings.jwt_secret_key, algorithms=["HS256"])
    assert claims["sub"] == "login_nuevo"
    assert claims["rol"] == "analista"


def test_auditoria_registra_creacion_sin_hash(client, admin_token, pg_admin_conn):
    resp = client.post(
        "/usuarios",
        json={"username": "auditado", "password": "ClavePrueba1", "rol": "cliente"},
        headers={"Authorization": f"Bearer {admin_token}"},
    )
    assert resp.status_code == 201
    nuevo_id = resp.json()["id"]

    fila = pg_admin_conn.execute(
        """
        SELECT usuario, operacion, datos_nuevos
        FROM auditoria
        WHERE tabla_afectada = 'usuarios' AND registro_id = %s
        ORDER BY id DESC LIMIT 1
        """,
        (nuevo_id,),
    ).fetchone()

    assert fila is not None
    assert fila["operacion"] == "INSERT"
    assert fila["usuario"] == "admin_test"
    assert "password_hash" not in fila["datos_nuevos"]


def test_crear_usuario_rol_invalido_devuelve_422(client, admin_token):
    resp = client.post(
        "/usuarios",
        json={"username": "rol_malo", "password": "ClavePrueba1", "rol": "superadmin"},
        headers={"Authorization": f"Bearer {admin_token}"},
    )

    assert resp.status_code == 422


def test_crear_usuario_password_corto_devuelve_422(client, admin_token):
    resp = client.post(
        "/usuarios",
        json={"username": "pass_corto", "password": "corto1", "rol": "cliente"},
        headers={"Authorization": f"Bearer {admin_token}"},
    )

    assert resp.status_code == 422
