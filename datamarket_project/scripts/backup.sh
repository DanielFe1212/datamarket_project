#!/usr/bin/env bash
# Respaldo de la base de datos (Paso 12 del enunciado).
#
# Uso:
#   PGPASSWORD=postgres ./scripts/backup.sh
#
# Variables de entorno (todas opcionales, con default coherente con
# docker/docker-compose.yml): PGHOST, PGPORT, PGUSER, PGDATABASE, BACKUP_DIR.
# PGPASSWORD SIEMPRE debe venir del entorno (export PGPASSWORD=... o un
# gestor de secretos) — nunca se pide como argumento ni se quema aquí.
#
# El puerto por defecto es 5433 (el del docker-compose). Si cambiaste POSTGRES_PORT, exporta PGPORT.

set -euo pipefail

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5433}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-datamarket}"
BACKUP_DIR="${BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backup}"

if [ -z "${PGPASSWORD:-}" ]; then
    echo "ERROR: define PGPASSWORD en el entorno antes de correr este script." >&2
    exit 1
fi

if ! command -v pg_dump >/dev/null 2>&1; then
    echo "ERROR: pg_dump no está instalado o no está en el PATH." >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

timestamp="$(date +%Y%m%d_%H%M%S)"
archivo="${BACKUP_DIR}/${PGDATABASE}_${timestamp}.backup"

echo "Respaldando ${PGDATABASE}@${PGHOST}:${PGPORT} -> ${archivo}"

pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -F c -f "$archivo"

if [ ! -s "$archivo" ]; then
    echo "ERROR: el backup no se generó o quedó vacío: ${archivo}" >&2
    exit 1
fi

tamano="$(du -h "$archivo" | cut -f1)"
echo "Backup OK"
echo "  archivo: ${archivo}"
echo "  tamaño:  ${tamano}"
echo "  fecha:   $(date -r "$archivo" '+%Y-%m-%d %H:%M:%S')"
