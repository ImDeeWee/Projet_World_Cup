WITH sexe_finales AS (
    SELECT DISTINCT
        m.id_match,
        e.nomPays,
        j.sexe
    FROM 
        matchs m
    INNER JOIN equipe e ON m.gagnant_id = e.id_equipe
    INNER JOIN possede p ON p.equipe_id = e.id_equipe
    INNER JOIN joueur j ON p.joueur_id = j.id_joueur
    WHERE m.rang = 'Finale'
)

SELECT 
    nomPays,
    COUNT(*) AS nombre_finales_gagnees,
    COUNT(CASE WHEN sexe = 'M' THEN 1 END) AS finales_masculines,
    COUNT(CASE WHEN sexe = 'F' THEN 1 END) AS finales_feminines
FROM 
    sexe_finales
GROUP BY 
    nomPays
ORDER BY 
    nombre_finales_gagnees DESC
LIMIT 10;

