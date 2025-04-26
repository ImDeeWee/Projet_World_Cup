import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text

engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# ─── 1. Lire les CSV
squads = pd.read_csv("world-cup-bd/data/squads.csv")
tours  = pd.read_csv("world-cup-bd/data/tournaments.csv")[["tournament_id", "year"]]

# ─── 2. Rattacher l’année au squad, puis dé-dupliquer pays + année
df = (
    squads.merge(tours, on="tournament_id", how="left")
          .rename(columns={"team_name": "nomPays", "year": "anneeCoupe"})
          .loc[:, ["nomPays", "anneeCoupe"]]
          .drop_duplicates()
)

# cast Int pour éviter “2022.0”
df["anneeCoupe"] = df["anneeCoupe"].astype(int)

# ─── 3. Export en mémoire, cellule vide = NULL
buf = StringIO()
df.to_csv(buf, index=False, header=False, na_rep="")
buf.seek(0)

# ─── 4. TRUNCATE + COPY
with engine.begin() as conn:
    conn.execute(text("TRUNCATE TABLE equipe RESTART IDENTITY CASCADE;"))
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY equipe (nomPays, anneeCoupe)
        FROM STDIN WITH CSV
        """,
        buf
    )

print(f"✅ {len(df)} équipes importées (pays × annéeCoupe).")
