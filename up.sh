#!/bin/bash

echo "🚀 Lancement du conteneur PostgreSQL..."

# Spécifie le chemin complet du fichier compose
docker-compose -f world-cup-bd/docker-compose.yml up -d

# Attendre un peu pour que le conteneur soit prêt
sleep 5

# Appeler le script de restauration avec le bon chemin
bash world-cup-bd/docker/scripts/pre-up.sh
