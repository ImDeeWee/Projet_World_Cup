import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text
import unicodedata

engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# 1) Charger les fichiers
refs = pd.read_csv("world-cup-bd/data/referees.csv")              # identité
apps = pd.read_csv("world-cup-bd/data/referee_appointments.csv")  # nominations

# 2) Fusionner pour récupérer le nom/prénom
df = apps.merge(refs, on="referee_id", how="left")

# 3) Ne garder qu’un seul enregistrement par arbitre
df = df.drop_duplicates(subset=["referee_id"], keep="first")

# 4) Normaliser les noms en ASCII simple
def normalize(s: str) -> str:
    return unicodedata.normalize("NFKD", str(s).strip()).encode("ascii", "ignore").decode()

df["prenom"] = df["given_name_y"].apply(normalize)
df["nom"]    = df["family_name_y"].apply(normalize)

# 5) Affecter un rôle par défaut (ici tous « Principal »)
df["rolearbitre"] = "Principal"

# 6) Préparer le DataFrame final
df_final = df[["rolearbitre", "prenom", "nom"]]

# 7) Exporter en mémoire et COPY
buf = StringIO()
df_final.to_csv(buf, index=False, header=False, na_rep="")
buf.seek(0)

with engine.begin() as conn:
    # Vidage et reset
    conn.execute(text("TRUNCATE TABLE arbitres RESTART IDENTITY CASCADE;"))
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY arbitres (rolearbitre, prenom, nom)
        FROM STDIN WITH CSV
        """,
        buf
    )

print(f"✅ {len(df_final)} arbitres importés dans la table “arbitres”.")