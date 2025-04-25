# 🌍 Projet World Cup BD – Setup de l'interface React et de la Base de Données PostgreSQL

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



### 3. Lancer PostgreSQL avec Docker et restaurer automatiquement la dernière sauvegarde

> ⚠️ Assure-toi que **Docker Desktop** est bien démarré sur ta machine avant de continuer.

#### Étapes :

1. Ouvre un terminal **Bash** et place-toi à la racine du projet (`Projet_World_Cup/`).
2. Lance le script suivant pour démarrer la base de données :

```bash
./up.sh
```


⏳ Patiente environ 5 secondes — la base de données sera automatiquement restaurée à partir de la [dernière version de la BD.](world-cup-bd/docker/db/backup.sql)

#### Pour arrêter la base proprement et sauvegarder :

```bash
./down.sh
```


### 4. Acceder a la base depuis son terminal (L'etape precedente doit etre faite)

```bash
docker exec -it postgres-wc psql -U wcuser -d worldcupdb
```

## 🔒 Informations pour se connecter à la base de données avec un IDE quelconque

| Paramètre       | Valeur        |
|------------------|---------------|
| **Hôte**         | `localhost`   |
| **Port**         | `5433`        |
| **Utilisateur**  | `wcuser`      |
| **Mot de passe** | `wcpass`      |
| **Base**         | `worldcupdb`  |

## ⚠️ Astuce pour probleme de connexion 

> Si tu as PostgreSQL installé **localement sur ta machine** (en dehors de Docker),  
> il se peut qu’il utilise déjà le **port 5432 et 5433**.  
> Résultat : Ta machine essaie de se connecter au serveur de ton postgresql locale au lieu de celui dans Docker.

✅ **Solution** :  
**Arrête le service PostgreSQL local** avant de démarrer DBeaver ou de te connecter à la base Docker.

### 📌 Comment faire

- Ouvre `Services` (tape `services.msc` dans la barre de recherche Windows)
- Trouve `postgresql` ou `postgresql-x64-XX`
- Clique droit → **Arrêter**

### Autre option
_Demande à un AI comment le faire.

Tu pourras ensuite te connecter sans problème à `localhost:5433`, qui sera désormais géré par Docker 🐳

---

[Lien StackOverflow du problème](https://stackoverflow.com/questions/74182080/docker-compose-w-postgresql-psql-password-authentication-failed)




