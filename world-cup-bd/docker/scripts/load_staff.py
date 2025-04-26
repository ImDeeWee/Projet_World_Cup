import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text
import unicodedata

engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# ---------- Fonctions utilitaires ----------
def normalize(s: str) -> str:
    s = str(s).strip()
    return unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()

# ---------- 1. Charger CSV ----------
managers  = pd.read_csv("world-cup-bd/data/managers.csv")
appoint   = pd.read_csv("world-cup-bd/data/manager_appointments.csv")

df = appoint.merge(managers, on="manager_id", how="left")

df["anneecoupe"] = df["tournament_id"].str.extract(r"(\d{4})").astype(int)
df.rename(columns={"team_name": "nompays"}, inplace=True)
df["nompays"] = df["nompays"].apply(normalize)

df["roleequipe"]  = "selectionneur"
df["prenomstaff"] = df.filter(regex="^given_name").bfill(axis=1).iloc[:, 0]
df["nomstaff"]    = df.filter(regex="^family_name").bfill(axis=1).iloc[:, 0]
for col in ["jourN", "moisN", "anneen"]:
    df[col] = pd.Series(dtype="Int64")

# ---------- 2. Associer les équipes ----------
equipes = pd.read_sql("SELECT id_equipe, nompays, anneecoupe FROM equipe", engine)
equipes["nompays"] = equipes["nompays"].apply(normalize)

df = df.merge(equipes, on=["nompays", "anneecoupe"], how="left")

missing = df[df["id_equipe"].isna()][["nompays", "anneecoupe"]].drop_duplicates()
if not missing.empty:
    print("⚠️ Équipes manquantes ignorées :", len(missing))
    df = df.dropna(subset=["id_equipe"])

df_final = df[[
    "roleequipe", "prenomstaff", "nomstaff",
    "jourN", "moisN", "anneen", "id_equipe"
]]

# ---------- 3. COPY en toute sécurité ----------
buf = StringIO()
df_final.to_csv(buf, index=False, header=False, na_rep="")
buf.seek(0)

with engine.begin() as conn:
    # 1) détache la FK côté equipe
    conn.execute(text("UPDATE equipe SET id_selectionneur = NULL;"))

    # 2) vide d’abord la table entraine (si elle existe), puis stafftechnique
    conn.execute(text("DELETE FROM entraine;"))
    conn.execute(text("DELETE FROM stafftechnique;"))

    # 3) remet l’auto-increment (PostgreSQL 12+)
    conn.execute(text("ALTER TABLE stafftechnique ALTER COLUMN id_staff RESTART WITH 1;"))

    # 4) COPY vers stafftechnique
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY stafftechnique
          (roleequipe, prenomstaff, nomstaff,
           jourN, moisN, anneen, id_equipe)
        FROM STDIN WITH CSV
        """,
        buf
    )

    # 5) ré-associe les sélectionneurs
    conn.execute(text("""
        UPDATE equipe e
        SET    id_selectionneur = s.id_staff
        FROM   stafftechnique s
        WHERE  s.id_equipe = e.id_equipe
          AND  s.roleequipe = 'selectionneur';
    """))



print(f"✅ {len(df_final)} sélectionneurs importés et liés aux équipes (sans FK errors).")
