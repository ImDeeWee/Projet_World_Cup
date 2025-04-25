#!/usr/bin/env bash
set -e

CONTAINER="postgres-wc"

echo "🗑️  Drop & recreate worldcupdb..."
docker exec "$CONTAINER" psql -U wcuser -d postgres \
  -c "DROP DATABASE IF EXISTS worldcupdb;"
docker exec "$CONTAINER" psql -U wcuser -d postgres \
  -c "CREATE DATABASE worldcupdb;"

echo "📦  Import /docker-backup.sql ..."
# On passe toute la ligne PSQL dans un bash -c à l'intérieur du conteneur
docker exec -i "$CONTAINER" bash -c \
  "psql -U wcuser -d worldcupdb -f /docker-backup.sql"

echo "✅  Base restaurée !"
