import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text

# ───────── Connexion à PostgreSQL
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# ───────── 1. Charger les CSV
players = pd.read_csv("world-cup-bd/data/players.csv")
squads  = pd.read_csv("world-cup-bd/data/squads.csv")

# Garder dans players uniquement birth_date + female
players_keep = players[["player_id", "birth_date", "female"]]

# Jointure squad ↔ players
df = squads.merge(players_keep, on="player_id", how="left")

# ───────── 2. Mapping vers le schéma de la table
df["id_joueur"]  = df["player_id"].str.extract(r"(\d+)").astype(int)
df["numero"]     = df["shirt_number"]
df["prenom"]     = df["given_name"]
df["nomfamille"] = df["family_name"]
df["sexe"]       = df["female"].map({0: "M", 1: "F"})

# Date de naissance → composantes
birth            = pd.to_datetime(df["birth_date"], errors="coerce")
df["jourN"]      = birth.dt.day.astype("Int64")
df["moisN"]      = birth.dt.month.astype("Int64")
df["anneen"]     = birth.dt.year.astype("Int64")   # même orthographe que ta colonne

# Garder exactement les 8 colonnes existantes
df = df[[
    "id_joueur", "numero", "prenom", "nomfamille",
    "jourN", "moisN", "anneen", "sexe"
]].drop_duplicates(subset=["id_joueur"])

# ───────── 3. Export CSV en mémoire (cellule vide = NULL)
buf = StringIO()
df.to_csv(buf, index=False, header=False, na_rep="")   #  <- vide
buf.seek(0)

# ───────── 4. TRUNCATE puis COPY
with engine.begin() as conn:
    conn.execute(text("TRUNCATE TABLE joueur RESTART IDENTITY CASCADE;"))
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY joueur
          (id_joueur, numero, prenom, nomfamille,
           jourN, moisN, anneen, sexe)
        FROM STDIN WITH CSV
        """,
        buf
    )


print(f"✅ {len(df)} joueurs importés sans erreur !")
