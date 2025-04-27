import express from "express";
import cors from "cors";
import dotenv from "dotenv";
import { query } from "./db.js";

dotenv.config();
const app = express();
app.use(cors());

// À faire
const sqlQueries = {
  q1: `
  WITH sexe_finales AS (
      SELECT DISTINCT
          m.id_match,
          e.nompays,
          j.sexe
      FROM 
          public.matchs m
      INNER JOIN public.equipe e ON m.gagnant_id = e.id_equipe
      INNER JOIN public.possede p ON p.equipe_id = e.id_equipe
      INNER JOIN public.joueur j ON p.joueur_id = j.id_joueur
      WHERE m.rang = 'Finale'
  )
  SELECT 
      nompays,
      COUNT(*) AS nombre_finales_gagnees,
      COUNT(CASE WHEN sexe = 'M' THEN 1 END) AS finales_masculines,
      COUNT(CASE WHEN sexe = 'F' THEN 1 END) AS finales_feminines
  FROM 
      sexe_finales
  GROUP BY 
      nompays
  ORDER BY 
      nombre_finales_gagnees DESC
  LIMIT 10;
    `,
  q2: `
  SELECT
      j.prenom,
      j.nomfamille,
      COUNT(*) AS total_cartons,
      COUNT(CASE WHEN f.typefaute = 'jaune' THEN 1 END) AS cartons_jaunes,
      COUNT(CASE WHEN f.typefaute = 'rouge' THEN 1 END) AS cartons_rouges
  FROM
      public.faute f
  INNER JOIN 
      public.joueur j ON f.joueur_id = j.id_joueur
  WHERE
      j.sexe = 'M'
  GROUP BY
      j.id_joueur, j.prenom, j.nomfamille
  ORDER BY
      total_cartons DESC, cartons_rouges DESC
  LIMIT 20;
    `,
  q3: `WITH joueurs_selectionneurs AS (
    SELECT 
        s.id_staff,
        s.prenomstaff,
        s.nomstaff,
        j.id_joueur
    FROM 
        selectionneur s
    INNER JOIN 
        joueur j
      ON LOWER(j.prenom) = LOWER(s.prenomstaff)
     AND LOWER(j.nomfamille) = LOWER(s.nomstaff)
)

SELECT 
    js.prenomstaff,
    js.nomstaff,
    -- 1) Les années où il a joué
    STRING_AGG(DISTINCT (e_joueur.anneecoupe)::text, ', ' 
               ORDER BY (e_joueur.anneecoupe)::text) 
      AS annees_joueur,
    -- 2) Le pays où il a joué
    e_joueur.nompays         AS nompays_joueur,
    -- 3) Les années où il a été sélectionneur
    STRING_AGG(DISTINCT (e_sel.anneecoupe)::text, ', ' 
               ORDER BY (e_sel.anneecoupe)::text) 
      AS annees_selectionneur,
    -- 4) Le pays qu’il entraîne
    e_sel.nompays            AS nompays_selectionneur
FROM 
    joueurs_selectionneurs js
    -- toutes les éditions où il a joué
    INNER JOIN possede p 
      ON p.joueur_id = js.id_joueur
    INNER JOIN equipe e_joueur 
      ON e_joueur.id_equipe = p.equipe_id
    -- sa/ ses sélections
    INNER JOIN selectionneur s 
      ON s.id_staff = js.id_staff
    INNER JOIN equipe e_sel 
      ON e_sel.id_equipe = s.id_equipe
GROUP BY 
    js.prenomstaff, 
    js.nomstaff, 
    e_joueur.nompays, 
    e_sel.nompays
ORDER BY 
    js.nomstaff, 
    js.prenomstaff;`,
  q4: `WITH
-- Victoires en tant que joueur
wins_player AS (
  SELECT
    j.prenom || ' ' || j.nomfamille AS personne,
    COUNT(*) AS wins_player
  FROM possede p
  JOIN joueur j ON j.id_joueur = p.joueur_id
  JOIN matchs m 
    ON m.rang = 'Finale'
   AND m.gagnant_id = p.equipe_id
  GROUP BY personne
),
-- Victoires en tant que coach
wins_coach AS (
  SELECT
    s.prenomstaff || ' ' || s.nomstaff AS personne,
    COUNT(*) AS wins_coach
  FROM selectionneur s
  JOIN equipe e ON e.id_equipe = s.id_equipe
  JOIN matchs m 
    ON m.rang = 'Finale'
   AND m.gagnant_id = e.id_equipe
  GROUP BY personne
),
-- Finales jouées comme joueur
finals_player AS (
  SELECT
    j.prenom || ' ' || j.nomfamille AS personne,
    COUNT(DISTINCT m.id_match) AS finals_player
  FROM possede p
  JOIN joueur j ON j.id_joueur = p.joueur_id
  JOIN matchs m
    ON m.rang = 'Finale'
   AND (m.id_equipea = p.equipe_id OR m.id_equipeb = p.equipe_id)
  GROUP BY personne
),
-- Finales jouées comme coach
finals_coach AS (
  SELECT
    s.prenomstaff || ' ' || s.nomstaff AS personne,
    COUNT(DISTINCT m.id_match) AS finals_coach
  FROM selectionneur s
  JOIN equipe e ON e.id_equipe = s.id_equipe
  JOIN matchs m
    ON m.rang = 'Finale'
   AND (m.id_equipea = e.id_equipe OR m.id_equipeb = e.id_equipe)
  GROUP BY personne
),
-- On fusionne les stats
combined AS (
  SELECT 
    COALESCE(wp.personne, wc.personne) AS personne,
    COALESCE(wp.wins_player, 0)  + COALESCE(wc.wins_coach, 0)  AS total_wins,
    COALESCE(fp.finals_player, 0) + COALESCE(fc.finals_coach, 0) AS total_finals
  FROM wins_player wp
  FULL  JOIN wins_coach  wc USING (personne)
  FULL  JOIN finals_player fp USING (personne)
  FULL  JOIN finals_coach  fc USING (personne)
)
SELECT
  personne,
  total_wins      AS coupes_gagnees,
  total_finals    AS finales_participees
FROM combined
ORDER BY total_wins DESC, total_finals DESC LIMIT 25;`,
};

for (const [route, sql] of Object.entries(sqlQueries)) {
  app.get(`/${route}`, async (req, res) => {
    try {
      const { rows } = await query(sql);
      res.json(rows);
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: err.message });
    }
  });
}

const PORT = process.env.PORT || 3001;
app.listen(PORT, () => console.log(`API running on port ${PORT}`));
