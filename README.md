# 🌍 Projet World Cup BD – Setup de la Base de Données PostgreSQL

Ce projet utilise **PostgreSQL via Docker** pour créer et gérer une base de données liée à la Coupe du Monde.  
Aucune installation directe de PostgreSQL n’est nécessaire localement.

---

## ✅ Prérequis

### 1. Docker (obligatoire)
- [🔗 Docker Desktop pour Windows](https://www.docker.com/products/docker-desktop/)
- [🔗 Docker Desktop pour Mac](https://www.docker.com/products/docker-desktop/)
**OU** (pour les utilisateurs Mac) via **Homebrew** :
```bash
brew install --cask docker
```



### 2. `npx` (installé avec Node.js)
- [🔗 Node.js (Windows/Mac)](https://nodejs.org/)  
  Choisis la version LTS recommandée. `npx` vient automatiquement avec l’installation de Node.js.

---

## 🚀 Démarrage rapide

### 1. **Clone le repo**
```bash
git clone https://github.com/ton-compte/Projet_World_Cup.git
cd Projet_World_Cup/world-cup-bd
````
### . Démarer la page React (rien fait encore)
```bash
npm install
npm start
```



### 3. Lancer PostgreSQL avec Docker (Assure-toi que Docker est **lancé** avant de continuer.)

```bash
docker-compose up --build
```

### 4. Acceder a la base depuis son terminal (L'etape precedente doit etre faite)

```bash
docker exec -it postgres-wc psql -U wcuser -d worldcupdb
```

## Informations pour se connecter à la BD

### Hôte
localhost

### Port
5433

### User
wcuser

### Password
wcpass

### Database
worldcupdb

**WARNING**: Si tu veux te connecter localement sur la BD ou via un IDE tel que DBeaver, tu dois arrêter ton postgresql local si tu l'as d'installé sur ta machine. Ask à un AI comment le faire.
[Lien StackOverflow du problème](https://stackoverflow.com/questions/74182080/docker-compose-w-postgresql-psql-password-authentication-failed)




