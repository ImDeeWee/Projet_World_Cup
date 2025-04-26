from faker import Faker
import pandas as pd
from io import StringIO
from sqlalchemy import create_engine, text

# Connexion à la base de données
engine = create_engine(
    "postgresql+psycopg2://wcuser:wcpass@localhost:5433/worldcupdb"
)

# Initialisation de Faker pour générer des noms fictifs
fake = Faker()

# Nombre d'arbitres secondaires à insérer
num_assistants = 916  # Ajustez entre 641 (1.3*493) et 986 (2*493) si nécessaire

# Génération des données fictives
data = []
for i in range(num_assistants):
    prenom = fake.first_name()
    nom = fake.last_name()
    data.append({"rolearbitre": "Assistant", "prenom": prenom, "nom": nom})

# Création d'un DataFrame avec les données
df = pd.DataFrame(data)

# Exportation des données en mémoire pour l'insertion
buf = StringIO()
df.to_csv(buf, index=False, header=False, na_rep="")
buf.seek(0)

# Insertion des données dans la table "arbitres"
with engine.begin() as conn:
    cur = conn.connection.cursor()
    cur.copy_expert(
        """
        COPY arbitres (rolearbitre, prenom, nom)
        FROM STDIN WITH CSV
        """,
        buf
    )

print(f"✅ {len(df)} faux arbitres secondaires importés dans la table “arbitres”.")