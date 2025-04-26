import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text
import unicodedata

# ——— Connexion
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

def norm(s: str) -> str:
    """Normalise chaîne en ASCII simple, minuscules et trim."""
    return unicodedata.normalize("NFKD", str(s).strip())\
                      .encode("ascii","ignore")\
                      .decode()\
                      .lower()

# ——— 1) Charger matches.csv et extraire date + équipes
m = pd.read_csv("world-cup-bd/data/matches.csv")
m["anneecoupe"] = m["tournament_id"].str.extract(r"(\d{4})").astype(int)
dt = pd.to_datetime(m["match_date"], errors="coerce")
m["jourm"] = dt.dt.day.astype("Int64")
m["moism"] = dt.dt.month.astype("Int64")
m["home_norm"] = m["home_team_name"].apply(norm)
m["away_norm"] = m["away_team_name"].apply(norm)

# ——— 2) Traduction des rangs anglais → ENUM français
stage_map = {
    "group stage":      "phase de pool",
    "second group stage": "phase de pool",
    "final round":      "phase de pool",
    "round of 16":      "1/8",
    "last 16":          "1/8",
    "quarter-final":    "1/4",
    "quarter-finals":   "1/4",
    "semi-final":       "1/2",
    "semi-finals":      "1/2",
    "third place":      "FinaleConsolation",
    "third-place match": "FinaleConsolation",
    "final":            "Finale",
}

m["stage_name"] = m["stage_name"].str.lower().str.strip().map(stage_map)
if m["stage_name"].isna().any():
    inconnus = m.loc[m["stage_name"].isna(), "stage_name"].unique()
    raise ValueError(f"Stage(s) non reconnus : {inconnus}")

# ——— 3) Récupérer id_equipe pour A et B
eq = pd.read_sql("SELECT id_equipe, nompays, anneecoupe FROM equipe", engine)
eq["nompays"] = eq["nompays"].apply(norm)

m = m.merge(
        eq.rename(columns={"nompays":"home_norm","id_equipe":"id_equipea"}),
        on=["home_norm","anneecoupe"], how="left"
    ).merge(
        eq.rename(columns={"nompays":"away_norm","id_equipe":"id_equipeb"}),
        on=["away_norm","anneecoupe"], how="left"
    )

# ——— 4) Calculer le gagnant_id
m["gagnant_id"] = m.apply(
    lambda r: r["id_equipea"]
              if r["home_team_score"] > r["away_team_score"]
              else (r["id_equipeb"]
                    if r["away_team_score"] > r["home_team_score"]
                    else pd.NA),
    axis=1
)

# ——— 5) Construire le DataFrame pour matchs
df_match = m[[
    "jourm", "moism", "stage_name", "stadium_name",
    "id_equipea", "id_equipeb", "gagnant_id"
]].rename(columns={
    "stage_name":   "rang",
    "stadium_name": "stade"
})
df_match["arbitreprincipal_id"] = pd.NA

# ——— 6) Préparer CSV en mémoire
buf_match = StringIO()
df_match.to_csv(buf_match, index=False, header=False, na_rep="")
buf_match.seek(0)

# ——— 7) TRUNCATE & COPY dans matchs (avec cascade FK approprié)
with engine.begin() as conn:
    conn.execute(text("""
        TRUNCATE donne,
                 scorefinal, gere, joue,
                 faute,
                 matchs
        RESTART IDENTITY CASCADE;
    """))
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY matchs
          (jourm, moism, rang, stade,
           id_equipea, id_equipeb, gagnant_id, arbitreprincipal_id)
        FROM STDIN WITH CSV
        """,
        buf_match
    )

    # ——— 8) Construire et insérer scorefinal avec scores de penalties
    inserted = pd.read_sql(
        "SELECT id_match, jourm, moism, id_equipea, id_equipeb FROM matchs",
        conn
    )
    scores = m.merge(
        inserted,
        on=["jourm","moism","id_equipea","id_equipeb"],
        how="left"
    )[[ "id_match", "home_team_score", "away_team_score", "home_team_score_penalties", "away_team_score_penalties", "penalty_shootout" ]]\
     .rename(columns={
         "home_team_score":"pointequipea",
         "away_team_score":"pointequipeb",
         "home_team_score_penalties":"penaltie_equipea",
         "away_team_score_penalties":"penaltie_equipeb"
     })

    # Convertir les scores de penalties en entiers
    scores['penaltie_equipea'] = scores['penaltie_equipea'].astype('Int64')
    scores['penaltie_equipeb'] = scores['penaltie_equipeb'].astype('Int64')

    # Set penalties to NULL where penalty_shootout is 0
    scores.loc[scores["penalty_shootout"] == 0, ["penaltie_equipea", "penaltie_equipeb"]] = None

    # Drop penalty_shootout
    scores = scores.drop(columns=["penalty_shootout"])

    buf_score = StringIO()
    scores.to_csv(buf_score, index=False, header=False)
    buf_score.seek(0)
    cur.copy_expert(
        """
        COPY scorefinal (match_id, pointequipea, pointequipeb, penaltie_equipea, penaltie_equipeb)
        FROM STDIN WITH CSV
        """,
        buf_score
    )

print(f"✅ {len(df_match)} matchs et {len(scores)} scores importés.")