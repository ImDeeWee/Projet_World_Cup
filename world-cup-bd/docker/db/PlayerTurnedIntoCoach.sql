WITH joueurs_selectionneurs AS (
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
    js.prenomstaff;
