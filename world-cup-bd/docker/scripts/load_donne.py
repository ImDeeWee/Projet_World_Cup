#!/usr/bin/env python3
import os
import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text
import unicodedata

# Connexion à la BD
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

def norm(s: str) -> str:
    return unicodedata.normalize("NFKD", str(s).strip()) \
                      .encode("ascii","ignore") \
                      .decode().lower()

# ——— Détection du chemin vers data/ ———
SCRIPT_DIR   = os.path.dirname(__file__)
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
DATA_DIR     = os.path.join(PROJECT_ROOT, "data")

# Chargement des CSV depuis data/
bookings_csv = pd.read_csv(os.path.join(DATA_DIR, "bookings.csv"))
referee_csv  = pd.read_csv(os.path.join(DATA_DIR, "referee_appearances.csv"))

# Préparation générique des dates et noms normés
for df in (bookings_csv, referee_csv):
    df["anneecoupe"]  = df["tournament_id"].str.extract(r"(\d{4})").astype(int)
    df["match_date"]  = pd.to_datetime(df["match_date"], errors="coerce")
    df["jourm"]       = df["match_date"].dt.day.astype("Int64")
    df["moism"]       = df["match_date"].dt.month.astype("Int64")
    # split + map(norm)
    tmp = df["match_name"].str.split(" vs ", expand=True)
    df["home_norm"] = tmp[0].map(norm)
    df["away_norm"] = tmp[1].map(norm)

# Récupération des matchs et des équipes
matches = pd.read_sql("SELECT id_match, jourm, moism, id_equipea, id_equipeb FROM matchs", engine)
equipes = pd.read_sql("SELECT id_equipe, nompays, anneecoupe FROM equipe", engine)
equipes["nompays_norm"] = equipes["nompays"].map(norm)

def map_teams(df):
    df = df.merge(
        equipes.rename(columns={"nompays_norm":"home_norm","id_equipe":"id_equipea"}),
        on=["home_norm","anneecoupe"], how="left"
    )
    df = df.merge(
        equipes.rename(columns={"nompays_norm":"away_norm","id_equipe":"id_equipeb"}),
        on=["away_norm","anneecoupe"], how="left"
    )
    return df.merge(matches, on=["jourm","moism","id_equipea","id_equipeb"], how="left")

bookings_csv = map_teams(bookings_csv)
referee_csv  = map_teams(referee_csv)

# Mapping arbitres vers referee_csv
referee_csv["given_norm"]  = referee_csv["given_name"].map(norm)
referee_csv["family_norm"] = referee_csv["family_name"].map(norm)
arbitres = pd.read_sql("SELECT id_arbitre, prenom, nom FROM arbitres", engine)
arbitres["prenom_norm"] = arbitres["prenom"].map(norm)
arbitres["nom_norm"]    = arbitres["nom"].map(norm)

referee_csv = referee_csv.merge(
    arbitres.rename(columns={"prenom_norm":"given_norm","nom_norm":"family_norm"}),
    on=["given_norm","family_norm"], how="left"
)

# Construction de df_donne
df_donne = bookings_csv.merge(referee_csv, on=["id_match","jourm","moism"], how="inner")

# Convertir player_id (chaîne) en entier pour pouvoir merger
df_donne["player_id"] = (
    df_donne["player_id"]
      .astype(str)
      .str.extract(r"(\d+)")
      .astype(int)
)

# Récupérer faute_id
fautes = pd.read_sql("SELECT faute_id, match_id, joueur_id FROM faute", engine)
df_donne = df_donne.merge(
    fautes,
    left_on=["id_match", "player_id"],
    right_on=["match_id", "joueur_id"],
    how="inner"
)


# Final : paires (arbitre_id, faute_id)
df_final = df_donne[["id_arbitre","faute_id"]].drop_duplicates()

# Insérer dans la table donne
buf = StringIO()
df_final.to_csv(buf, index=False, header=False)
buf.seek(0)

with engine.begin() as conn:
    conn.execute(text("TRUNCATE TABLE donne RESTART IDENTITY CASCADE;"))
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY donne (arbitre_id, faute_id)
        FROM STDIN WITH CSV
        """,
        buf
    )

print(f"✅ {len(df_final)} lignes insérées dans la table 'donne'.")
