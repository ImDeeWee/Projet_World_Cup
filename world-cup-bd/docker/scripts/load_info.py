import pandas as pd
from sqlalchemy import create_engine, text

# 1) Connexion PostgreSQL (adapte le port si besoin)
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# 2) Charger le CSV des tournois
df = pd.read_csv("world-cup-bd/data/tournaments.csv")

# 3) Conserver uniquement les Coupes du Monde masculines
df = df[df["tournament_name"].str.contains("Men")]

# 4) Transformer les dates
df["start_date"] = pd.to_datetime(df["start_date"])
df["end_date"]   = pd.to_datetime(df["end_date"])

# 5) Extraire les composantes
df["annee"]  = df["year"].astype(int)
df["jourd"]  = df["start_date"].dt.day.astype(int)
df["moisd"]  = df["start_date"].dt.month.astype(int)
df["jourf"]  = df["end_date"].dt.day.astype(int)
df["moisf"]  = df["end_date"].dt.month.astype(int)

# 6) Garder les colonnes cibles
df = df[["annee", "jourd", "moisd", "jourf", "moisf"]]

# 7) Vider la table (FK vers coupedumondehote → CASCADE requis)
with engine.begin() as conn:
    conn.execute(text(
        "TRUNCATE TABLE coupedumondeinfo RESTART IDENTITY CASCADE;"
    ))

# 8) Insérer
df.to_sql("coupedumondeinfo", engine, if_exists="append", index=False)

print("✅ Table coupedumondeinfo remplie !")
