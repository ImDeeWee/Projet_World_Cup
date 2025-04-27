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
  q2: "SELECT ... -- requête 2",
  q3: "SELECT ... -- requête 3",
  q4: "SELECT ... -- requête 4",
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
