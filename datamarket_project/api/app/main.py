from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.db import close_pool, open_pool
from app.routers import auth, inventario, pedidos, productos, usuarios


@asynccontextmanager
async def lifespan(app: FastAPI):
    open_pool()
    yield
    close_pool()


app = FastAPI(title="DataMarket API", lifespan=lifespan)

app.include_router(auth.router)
app.include_router(usuarios.router)
app.include_router(productos.router)
app.include_router(inventario.router)
app.include_router(pedidos.router)
