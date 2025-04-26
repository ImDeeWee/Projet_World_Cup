import pandas as pd
from sqlalchemy import create_engine, text
import random

# Connexion
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# 1) Charger tous les matchs avec leur arbitre principal (même s'il est NULL)
with engine.connect() as conn:
    df_matches = pd.read_sql(
        "SELECT id_match, arbitreprincipal_id FROM matchs",
        conn
    )

# 2) Charger la liste des assistants
with engine.connect() as conn:
    df_assistants = pd.read_sql(
        "SELECT id_arbitre FROM arbitres WHERE rolearbitre = 'Assistant'",
        conn
    )
assistant_list = df_assistants["id_arbitre"].tolist()

# 3) Préparer les tuples à insérer
gere_data = []
for _, row in df_matches.iterrows():
    match_id       = int(row["id_match"])
    principal_id   = None if pd.isna(row["arbitreprincipal_id"]) \
                     else int(row["arbitreprincipal_id"])
    # choisir 3 assistants distincts
    selected = random.sample(assistant_list, 3)
    gere_data.append((
        match_id,
        principal_id,
        selected[0],
        selected[1],
        selected[2]
    ))

# 4) TRUNCATE + INSERT en batch
with engine.begin() as conn:
    # 4a) vider la table gere (cascade si besoin)
    conn.execute(text("TRUNCATE TABLE gere RESTART IDENTITY CASCADE;"))
    # 4b) insérer tous les couples match/assistants
    cur = conn.connection.cursor()
    cur.executemany(
        """
        INSERT INTO gere
          (match_id,
           arbitre_principal_id,
           arbitre_secondaire1_id,
           arbitre_secondaire2_id,
           arbitre_secondaire3_id)
        VALUES (%s,%s,%s,%s,%s)
        """,
        gere_data
    )
    # (pas besoin de conn.connection.commit() : engine.begin() commit automatiquement)

print(f"✅ {len(gere_data)} lignes insérées dans la table `gere`.")
