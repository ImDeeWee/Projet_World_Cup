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
### 2. Démarer la page React (rien fait encore)
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

## 🔒 Informations pour se connecter à la base de données

| Paramètre       | Valeur        |
|------------------|---------------|
| **Hôte**         | `localhost`   |
| **Port**         | `5433`        |
| **Utilisateur**  | `wcuser`      |
| **Mot de passe** | `wcpass`      |
| **Base**         | `worldcupdb`  |

## ⚠️ Astuce DBeaver (Windows)

> Si tu as PostgreSQL installé **localement sur ta machine Windows** (en dehors de Docker),  
> il se peut qu’il utilise déjà le **port 5432**.  
> Résultat : DBeaver essaie de se connecter au serveur local au lieu de celui dans Docker.

✅ **Solution** :  
**Arrête le service PostgreSQL local** avant de démarrer DBeaver ou de te connecter à la base Docker.

### 📌 Comment faire

- Ouvre `Services` (tape `services.msc` dans la barre de recherche Windows)
- Trouve `postgresql` ou `postgresql-x64-XX`
- Clique droit → **Arrêter**

Tu pourras ensuite te connecter sans problème à `localhost:5432`, qui sera désormais géré par Docker 🐳

---

[Lien StackOverflow du problème](https://stackoverflow.com/questions/74182080/docker-compose-w-postgresql-psql-password-authentication-failed)




