#!/bin/bash

echo "🔍 Checking if PostgreSQL volume is empty..."

TABLE_COUNT=$(docker exec postgres-wc psql -U wcuser -d worldcupdb -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" | xargs)

if [ "$TABLE_COUNT" -eq "0" ]; then
    echo "📥 Restoring from snapshot..."
    docker exec -i postgres-wc psql -U wcuser -d worldcupdb < world-cup-bd/docker/db/backup.sql
    echo "✅ Snapshot restored."
else
    echo "🟢 DB already initialized – skipping restore."
fi
