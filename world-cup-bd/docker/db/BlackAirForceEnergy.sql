SELECT
    j.prenom,
    j.nomfamille,
    COUNT(*) AS total_cartons,
    COUNT(CASE WHEN f.typefaute = 'jaune' THEN 1 END) AS cartons_jaunes,
    COUNT(CASE WHEN f.typefaute = 'rouge' THEN 1 END) AS cartons_rouges
FROM
    faute f
INNER JOIN 
    joueur j ON f.joueur_id = j.id_joueur
WHERE
    j.sexe = 'M'
GROUP BY
    j.id_joueur, j.prenom, j.nomfamille
ORDER BY
    total_cartons DESC, cartons_rouges DESC
LIMIT 20;
