import pandas as pd
from sqlalchemy import create_engine, text
import unicodedata

# Connexion
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

def norm(s: str) -> str:
    """Normalize à l’ASCII lowercased without accents."""
    return unicodedata.normalize("NFKD", str(s).strip())\
                      .encode("ascii", "ignore")\
                      .decode()\
                      .lower()

# 1) Charger referee_appearances.csv
apps = pd.read_csv("world-cup-bd/data/referee_appearances.csv")

# 2) Extraire anneecoupe, jourm, moism
apps["anneecoupe"] = apps["tournament_id"].str.extract(r"(\d{4})").astype(int)
apps["match_date"] = pd.to_datetime(apps["match_date"], errors="coerce")
apps["jourm"]      = apps["match_date"].dt.day.astype("Int64")
apps["moism"]      = apps["match_date"].dt.month.astype("Int64")

# 3) Séparer home vs away depuis match_name
apps[["home_team_name", "away_team_name"]] = apps["match_name"]\
    .str.split(" vs ", expand=True)

# 4) Normaliser et récupérer les id_equipe
apps["home_norm"] = apps["home_team_name"].apply(norm)
apps["away_norm"] = apps["away_team_name"].apply(norm)

# Lecture de la table equipe
df_equipe = pd.read_sql("SELECT id_equipe, nompays, anneecoupe FROM equipe", engine)
df_equipe["nompays_norm"] = df_equipe["nompays"].apply(norm)

# Mapping (home, away) → id_equipea/b
apps = apps.merge(
    df_equipe.rename(columns={"nompays_norm": "home_norm", "id_equipe": "id_equipea"}),
    on=["home_norm", "anneecoupe"], how="left"
).merge(
    df_equipe.rename(columns={"nompays_norm": "away_norm", "id_equipe": "id_equipeb"}),
    on=["away_norm", "anneecoupe"], how="left"
)

# 5) Récupérer id_match
df_matchs = pd.read_sql(
    "SELECT id_match, jourm, moism, id_equipea, id_equipeb FROM matchs", engine
)
apps = apps.merge(
    df_matchs,
    on=["jourm", "moism", "id_equipea", "id_equipeb"],
    how="left"
)

# 6) Normaliser les noms d’arbitres et récupérer id_arbitre
apps["given_norm"]  = apps["given_name"].apply(norm)
apps["family_norm"] = apps["family_name"].apply(norm)

df_arb = pd.read_sql(
    "SELECT id_arbitre, prenom, nom FROM arbitres WHERE rolearbitre='Principal'",
    engine
)
df_arb["prenom_norm"] = df_arb["prenom"].apply(norm)
df_arb["nom_norm"]    = df_arb["nom"].apply(norm)

apps = apps.merge(
    df_arb.rename(columns={"prenom_norm": "given_norm", "nom_norm": "family_norm",
                           "id_arbitre": "id_arbitre"}),
    on=["given_norm", "family_norm"], how="left"
)

# 7) Préparer la liste des updates
updates = apps.dropna(subset=["id_match", "id_arbitre"])\
              .loc[:, ["id_match", "id_arbitre"]]\
              .drop_duplicates()

print(f"⚙️  {len(updates)} correspondances match→arbitre trouvées. Exemples :")
print(updates.head())

# 8) Exécuter le batch UPDATE
with engine.begin() as conn:
    stmt = text("""
        UPDATE matchs
           SET arbitreprincipal_id = :arbitre_id
         WHERE id_match            = :match_id
    """)
    conn.execute(
        stmt,
        [
            {"match_id": int(r.id_match), "arbitre_id": int(r.id_arbitre)}
            for r in updates.itertuples(index=False)
        ]
    )

print("✅ Mise à jour de la colonne arbitreprincipal_id terminée.")
