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
docker run -it --rm --network host postgres psql -h 127.0.0.1 -U wcuser -d worldcupdb
```

PS: j'ai essayé de rouler la BD sur DBeaver, mais je ne sais pas pourquoi, mais mon windows ne voulait pas se connecter sur la DB. You better look on youtube to do it, which is something that I didn't do.



