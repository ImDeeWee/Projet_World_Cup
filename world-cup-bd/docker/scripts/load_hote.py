import pandas as pd
from sqlalchemy import create_engine, text

# Connexion à PostgreSQL (adapte le port si besoin)
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# 1) Charger le CSV hôtes
df = pd.read_csv("world-cup-bd/data/host_countries.csv")

# 2) Garder uniquement les Coupes du Monde masculines
df = df[df["tournament_name"].str.contains("Men")]

# 3) Extraire l’année -> annee
df["annee"] = df["tournament_id"].str.extract(r'(\d{4})').astype(int)

# 4) Garder annee + pays, renommer la colonne
df = (
    df[["annee", "team_name"]]        # team_name = pays hôte
      .rename(columns={"team_name": "payshote"})
)

# 5) Fusionner les co-hôtes la même année (ex. 2002)
df = (
    df.groupby("annee", as_index=False)
      .agg({"payshote": " & ".join})
)

# 6) Vider la table avant insertion (TRUNCATE avec CASCADE)
with engine.begin() as conn:
    conn.execute(text(
        "TRUNCATE TABLE coupedumondehote RESTART IDENTITY CASCADE;"
    ))

# 7) Insérer sans doublons
df.to_sql("coupedumondehote", engine, if_exists="append", index=False)

print("✅ Table coupedumondehote remplie sans doublons (Option A).")
