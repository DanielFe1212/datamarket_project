"""Fixtures de pytest para el módulo de gestión de usuarios.

Usa una base de datos separada `datamarket_test` (mismo servidor Postgres de
docker/docker-compose.yml) para no tocar datos de desarrollo. Antes de correr
estos tests hay que crear esa base y ejecutar los scripts de database/ contra
ella (ver README.md, sección de pruebas).
"""

import os

import psycopg
import pytest
from fastapi.testclient import TestClient
from psycopg.rows import dict_row

from app.db import get_db
from app.main import app
from app.security import hash_password

TEST_PG_ADMIN_DSN = os.environ.get(
    "TEST_PG_ADMIN_DSN", "postgresql://postgres:postgres@localhost:5433/datamarket_test"
)
TEST_APP_API_DSN = os.environ.get(
    "TEST_APP_API_DSN",
    "postgresql://app_api:app_api_dev_only@localhost:5433/datamarket_test",
)

ADMIN_USERNAME = "admin_test"
ADMIN_PASSWORD = "AdminTest#2026"
OPERADOR_USERNAME = "operador_test"
OPERADOR_PASSWORD = "OperadorTest#2026"


@pytest.fixture(scope="session")
def pg_admin_conn():
    conn = psycopg.connect(TEST_PG_ADMIN_DSN, autocommit=True, row_factory=dict_row)
    yield conn
    conn.close()


@pytest.fixture(autouse=True)
def clean_db(pg_admin_conn):
    pg_admin_conn.execute("TRUNCATE usuarios, auditoria RESTART IDENTITY CASCADE")
    pg_admin_conn.execute(
        "INSERT INTO usuarios (username, password_hash, rol) VALUES (%s, %s, 'admin')",
        (ADMIN_USERNAME, hash_password(ADMIN_PASSWORD)),
    )
    pg_admin_conn.execute(
        "INSERT INTO usuarios (username, password_hash, rol) VALUES (%s, %s, 'operador')",
        (OPERADOR_USERNAME, hash_password(OPERADOR_PASSWORD)),
    )
    yield


@pytest.fixture(scope="session")
def client():
    # Session-scoped: el ConnectionPool de app.db es un objeto único que solo
    # puede abrirse/cerrarse una vez (el lifespan de FastAPI lo abre/cierra). Un
    # fixture por-test re-ejecutaría ese ciclo en cada test y la segunda
    # apertura falla con PoolClosed; por eso un solo TestClient para toda la
    # sesión de pytest. El aislamiento entre tests lo da clean_db (autouse).
    def _get_test_db():
        with psycopg.connect(TEST_APP_API_DSN) as conn:
            yield conn

    app.dependency_overrides[get_db] = _get_test_db
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.pop(get_db, None)


@pytest.fixture
def admin_token(client):
    resp = client.post("/auth/login", json={"username": ADMIN_USERNAME, "password": ADMIN_PASSWORD})
    assert resp.status_code == 200
    return resp.json()["access_token"]


@pytest.fixture
def operador_token(client):
    resp = client.post(
        "/auth/login", json={"username": OPERADOR_USERNAME, "password": OPERADOR_PASSWORD}
    )
    assert resp.status_code == 200
    return resp.json()["access_token"]
