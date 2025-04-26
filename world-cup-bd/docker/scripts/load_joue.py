# load_joue.py

import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text

# ——— Connexion à la base de données
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# 1) Récupérer id_match, id_equipea et id_equipeb depuis matchs
with engine.connect() as conn:
    df = pd.read_sql(
        "SELECT id_match, id_equipea, id_equipeb FROM matchs",
        conn
    )

# 2) Préparer le CSV en mémoire (sans en-têtes)
buf = StringIO()
df.to_csv(buf, index=False, header=False, na_rep="")
buf.seek(0)

# 3) TRUNCATE puis COPY dans joue
with engine.begin() as conn:
    # Vider la table joue et rétablir l’état initial des FK
    conn.execute(text("TRUNCATE TABLE joue RESTART IDENTITY CASCADE;"))
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY joue (id_match, id_equipea, id_equipeb)
          FROM STDIN WITH CSV
        """,
        buf
    )

print(f"✅ {len(df)} lignes insérées dans la table “joue”.")
