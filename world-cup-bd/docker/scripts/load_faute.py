#!/usr/bin/env python3
import os
import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text
import unicodedata

# 0) Connexion
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

def normalize(s: str) -> str:
    return unicodedata.normalize("NFKD", str(s).strip()) \
                      .encode("ascii","ignore") \
                      .decode().lower()

# 1) repère la racine du projet (2 niveaux au-dessus de ce script)
SCRIPT_DIR   = os.path.dirname(__file__)
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))

# 2) chemin absolu vers bookings.csv
DATA_CSV = os.path.join(PROJECT_ROOT, "data", "bookings.csv")

# 3) charge le CSV
df = pd.read_csv(DATA_CSV)

# 4) Extraire année + date
df["anneecoupe"] = df["tournament_id"].str.extract(r"(\d{4})").astype(int)
df["match_date"] = pd.to_datetime(df["match_date"], errors="coerce")
df["jourm"]      = df["match_date"].dt.day.astype("Int64")
df["moism"]      = df["match_date"].dt.month.astype("Int64")

# 5) Extraire et normaliser Home/Away à partir de match_name
df[["home_team_name","away_team_name"]] = (
    df["match_name"]
      .str.split(" vs ", expand=True)
)
df["home_norm"] = df["home_team_name"].apply(normalize)
df["away_norm"] = df["away_team_name"].apply(normalize)

# 6) Récupérer id_equipea / id_equipeb
eq = pd.read_sql("SELECT id_equipe, nompays, anneecoupe FROM equipe", engine)
eq["nompays_norm"] = eq["nompays"].apply(normalize)
df = df.merge(
    eq.rename(columns={"nompays_norm":"home_norm","id_equipe":"id_equipea"}),
    on=["home_norm","anneecoupe"], how="left"
).merge(
    eq.rename(columns={"nompays_norm":"away_norm","id_equipe":"id_equipeb"}),
    on=["away_norm","anneecoupe"], how="left"
)

# debug juste après le merge équipes
print(f"Lignes sans id_equipea : {df['id_equipea'].isna().sum()}")
print(f"Lignes sans id_equipeb : {df['id_equipeb'].isna().sum()}")

# 7) Récupérer id_match
matches = pd.read_sql(
    "SELECT id_match, jourm, moism, id_equipea, id_equipeb FROM matchs",
    engine
)
df = df.merge(matches, on=["jourm","moism","id_equipea","id_equipeb"], how="left")

# debug juste avant l’insertion finale
print(f"Total lignes dans bookings.csv : {len(df)}")
print(f"Lignes sans id_match : {df['id_match'].isna().sum()}")

# 8) Extraire id_joueur numérique
df["joueur_id"] = df["player_id"].str.extract(r"(\d+)").astype(int)

# 9) Déterminer type de faute (en conformité avec votre enum type_faute)
def pick_type(r):
    if r["red_card"] == 1 or r["sending_off"] == 1:
        return "rouge"
    if r["yellow_card"] == 1 or r["second_yellow_card"] == 1:
        return "jaune"
    return None

df["typefaute"]    = df.apply(pick_type, axis=1)
df["faute_minute"] = df["minute_regulation"].fillna(0) + df["minute_stoppage"].fillna(0)

# 10) Préparer le DataFrame à copier
to_ins = df[["joueur_id","id_match","typefaute","faute_minute"]].dropna(subset=["id_match","joueur_id","typefaute"])

# 11) Filtrer selon la contrainte CHECK (1 <= faute_minute < 125)
to_ins = to_ins[(to_ins["faute_minute"] > 0) & (to_ins["faute_minute"] < 125)]
print(f"Fautes après filtrage minutes invalides : {len(to_ins)}")

# 12) COPY dans la table faute
buf = StringIO()
to_ins.to_csv(buf, index=False, header=False, na_rep="")
buf.seek(0)

with engine.begin() as conn:
    conn.execute(text("TRUNCATE TABLE faute RESTART IDENTITY CASCADE;"))
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY faute (joueur_id, match_id, typefaute, faute_minute)
        FROM STDIN WITH CSV
        """,
        buf
    )

print(f"✅ {len(to_ins)} fautes importées.")
