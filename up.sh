#!/usr/bin/env bash
set -e

# 📂 1) Se placer dans le dossier où se trouve up.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 📄 2) Chemin vers le compose du projet
COMPOSE_FILE="world-cup-bd/docker-compose.yml"

echo "🔄 Pull des dernières images..."
docker-compose -f "$COMPOSE_FILE" pull

echo "🛑 Arrêt et suppression des conteneurs existants (optionnel)"
docker-compose -f "$COMPOSE_FILE" down

echo "🚀 Démarrage en buildant et recréant tout"
docker-compose -f "$COMPOSE_FILE" up -d --build --force-recreate

echo "✅ Conteneurs up-to-date !"

# (Optionnel) restauration de la base de données
echo "🚀 Restauration de la base de données..."
bash world-cup-bd/docker/scripts/pre-up.sh
