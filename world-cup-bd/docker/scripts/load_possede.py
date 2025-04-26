import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text
import unicodedata

engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# ——— 1. CSV : squads + tournaments
squads = pd.read_csv("world-cup-bd/data/squads.csv")
tours  = pd.read_csv("world-cup-bd/data/tournaments.csv")[["tournament_id", "year"]]

squads = squads.merge(tours, on="tournament_id", how="left") \
               .rename(columns={"team_name": "nompays", "year": "anneecoupe"})

# ——— 2. Normaliser le nom de pays (accents/espaces)
def norm(s: str) -> str:
    return unicodedata.normalize("NFKD", str(s).strip()).encode("ascii", "ignore").decode()

squads["nompays"] = squads["nompays"].apply(norm)

# ——— 3. Préparer les IDs
squads["id_joueur"] = squads["player_id"].str.extract(r"(\d+)").astype(int)
squads["anneecoupe"] = squads["anneecoupe"].astype(int)

# ——— 4. Récupérer les équipes depuis la BD
equipes = pd.read_sql("SELECT id_equipe, nompays, anneecoupe FROM equipe", engine)
equipes["nompays"] = equipes["nompays"].apply(norm)

df = squads.merge(equipes, on=["nompays", "anneecoupe"], how="left")

# ——— 5. Vérifier les lignes sans équipe (optionnel)
manquants = df[df["id_equipe"].isna()][["nompays", "anneecoupe"]].drop_duplicates()
if not manquants.empty:
    print("⚠️ Possède ignoré pour lignes sans équipe :", len(manquants))
    df = df.dropna(subset=["id_equipe"])

# ——— 6. Garder seulement (id_equipe, id_joueur)
possede = df[["id_equipe", "id_joueur"]].drop_duplicates()

# ——— 7. Export CSV mémoire
buf = StringIO()
possede.to_csv(buf, index=False, header=False)
buf.seek(0)

# ——— 8. Remplir la table possede
with engine.begin() as conn:
    conn.execute(text("TRUNCATE TABLE possede;"))      # pas de FK vers possede
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY possede (equipe_id, joueur_id)
        FROM STDIN WITH CSV
        """,
        buf
    )

print(f"✅ {len(possede)} relations équipe ↔ joueur importées dans possede.")
