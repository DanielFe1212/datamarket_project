from collections.abc import Iterator

from psycopg import Connection
from psycopg_pool import ConnectionPool

from app.config import settings

pool = ConnectionPool(conninfo=settings.database_url, open=False)


def open_pool() -> None:
    pool.open(wait=True)


def close_pool() -> None:
    pool.close()


def get_db() -> Iterator[Connection]:
    with pool.connection() as conn:
        yield conn
