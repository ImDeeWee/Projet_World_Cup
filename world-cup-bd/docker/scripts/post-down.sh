#!/bin/bash

echo "📤 Saving PostgreSQL snapshot..."

docker exec -t postgres-wc pg_dump -U wcuser worldcupdb > world-cup-bd/docker/db/backup.sql

if [ $? -eq 0 ]; then
    echo "✅ Snapshot saved to world-cup-bd/docker/db/backup.sql"
else
    echo "❌ Failed to save snapshot"
fi
