CREATE TABLE IF NOT EXISTS CoupeDuMonde (
  annee INT PRIMARY KEY,
  paysHote VARCHAR(100),
  jourD INT,
  moisD INT,
  jourF INT,
  moisF INT
);

CREATE TABLE IF NOT EXISTS Joueur (
  id_joueur INT PRIMARY KEY,
  numero INT,
  nomPays VARCHAR(50),
  anneeCoupe INT,
  prenom VARCHAR(50),
  nomFamille VARCHAR(50),
  jourN INT,
  moisN INT,
  anneeN INT
);

-- Ajoute les autres tables ici
