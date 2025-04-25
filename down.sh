#!/bin/bash

# Sauvegarde avant arrêt
bash world-cup-bd/docker/scripts/post-down.sh

# Ajout automatique du snapshot à Git
git add world-cup-bd/docker/db/backup.sql
echo "✅ backup.sql ajouté à Git (n'oublie pas de commit si nécessaire)"

echo "🛑 Arrêt du conteneur PostgreSQL..."
docker-compose -f world-cup-bd/docker-compose.yml down

