WITH
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
ORDER BY total_wins DESC, total_finals DESC LIMIT 25;
