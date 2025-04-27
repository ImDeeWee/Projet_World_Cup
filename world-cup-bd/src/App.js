import React, { useState } from 'react';
import './App.css';

const API_URL = process.env.REACT_APP_API_URL;

const questions = [
  {
    id: 1,
    text: "Quels sont les 10 pays ayant remporté le plus de finales, en distinguant les victoires masculines et féminines ?",
  },
  {
    id: 2,
    text: "Quels sont les 20 joueurs masculins ayant reçu le plus de cartons, en précisant combien sont jaunes et combien sont rouges ?",
  },
  {
    id: 3,
    text: " Pour chaque personne ayant d’abord joué en équipe nationale puis exercé comme sélectionneur, indiquer (1) les années où elle a joué ; (2) le pays qu’elle représentait comme joueur ; (3) les années où elle a été sélectionneur ; (4) le pays qu’elle a entraîné.",
  },
  {
    id: 4,
    text: "Quelles sont les 25 personnes qui ont le plus grand nombre de coupes remportées (totales joueur + sélectionneur) et, pour chacune, combien de finales elles ont disputées au total ?",
  },
];

function App() {
  const [data, setData] = useState([]);
  const [error, setError] = useState(null);

  const fetchData = async (n) => {
    try {
      setError(null);
      const res = await fetch(`${API_URL}/q${n}`);
      if (!res.ok) throw new Error(`Statut ${res.status}`);
      const json = await res.json();
      setData(json);
    } catch (e) {
      setError(e.message);
      setData([]);
    }
  };

  return (
    <div className="app">
      <header className="header">
        <h1>🌍⚽ Coupe du Monde</h1>
      </header>

      <div className="questions">
        {questions.map((q) => (
          <div className="question-container" key={q.id}>
            <p className="question-text">{q.text}</p>
            <button
              className="question-button"
              onClick={() => fetchData(q.id)}
            >
              Afficher
            </button>
          </div>
        ))}
      </div>

      {error && <p className="error">Erreur : {error}</p>}

      {data.length > 0 && (
        <table className="results">
          <thead>
            <tr>
              {Object.keys(data[0]).map((col) => (
                <th key={col}>{col}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {data.map((row, i) => (
              <tr key={i}>
                {Object.values(row).map((val, j) => (
                  <td key={j}>{val}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}


export default App;
