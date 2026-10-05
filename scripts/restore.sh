#!/usr/bin/env bash
# Restauración de un respaldo (Paso 13 del enunciado). Por defecto restaura
# sobre una base separada (datamarket_restaurada) para no tocar la base de
# desarrollo mientras se simula el incidente/recuperación.
#
# Uso:
#   PGPASSWORD=postgres ./scripts/restore.sh [archivo.backup] [base_destino]
#
# Si no se indica archivo, usa el backup más reciente de backup/.
# Si no se indica base_destino, usa "datamarket_restaurada".
#
# Variables de entorno (mismos defaults que backup.sh): PGHOST, PGPORT, PGUSER.
# PGPASSWORD siempre debe venir del entorno, nunca como argumento.

set -euo pipefail

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5433}"
PGUSER="${PGUSER:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backup}"

archivo="${1:-}"
destino="${2:-datamarket_restaurada}"

if [ -z "${PGPASSWORD:-}" ]; then
    echo "ERROR: define PGPASSWORD en el entorno antes de correr este script." >&2
    exit 1
fi

if ! command -v pg_restore >/dev/null 2>&1; then
    echo "ERROR: pg_restore no está instalado o no está en el PATH." >&2
    exit 1
fi

if [ -z "$archivo" ]; then
    archivo="$(ls -t "${BACKUP_DIR}"/*.backup 2>/dev/null | head -n1 || true)"
    if [ -z "$archivo" ]; then
        echo "ERROR: no se indicó archivo y no hay ningún *.backup en ${BACKUP_DIR}" >&2
        exit 1
    fi
    echo "Usando el backup más reciente: ${archivo}"
fi

if [ ! -f "$archivo" ]; then
    echo "ERROR: no existe el archivo ${archivo}" >&2
    exit 1
fi

existe_db="$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${destino}'")"

if [ "$existe_db" != "1" ]; then
    echo "Creando base de datos de destino: ${destino}"
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -c "CREATE DATABASE \"${destino}\";" >/dev/null
fi

echo "Restaurando ${archivo} -> ${destino}@${PGHOST}:${PGPORT}"
pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$destino" \
    --clean --if-exists --no-owner "$archivo"

echo "Restauración OK. Verificación rápida de conteos:"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$destino" -c "
    SELECT 'usuarios' AS tabla, count(*) FROM usuarios
    UNION ALL SELECT 'categorias', count(*) FROM categorias
    UNION ALL SELECT 'productos', count(*) FROM productos
    UNION ALL SELECT 'pedidos', count(*) FROM pedidos
    ORDER BY tabla;
"
