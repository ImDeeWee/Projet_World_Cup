#!/usr/bin/env bash
set -e

# 📂 1) Se placer dans le dossier où se trouve up.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 📄 2) Chemin vers le docker-compose du projet
COMPOSE_FILE="world-cup-bd/docker-compose.yml"

echo "🔄 Pull des dernières images..."
docker-compose -f "$COMPOSE_FILE" pull

echo "🛑 Arrêt et suppression des conteneurs existants (optionnel)"
docker-compose -f "$COMPOSE_FILE" down

echo "🚀 Démarrage en buildant et recréant tout"
docker-compose -f "$COMPOSE_FILE" up -d --build --force-recreate

echo "⏳ Attente du démarrage de PostgreSQL..."
sleep 3   # ajuste au besoin

echo "📂 Restauration de la base de données depuis backup.sql..."
bash world-cup-bd/docker/scripts/restore.sh

echo "✅ Conteneurs et base de données à jour !"
