import React, { useState } from 'react';
import './App.css';

const API_URL = process.env.REACT_APP_API_URL;

const questions = [
  {
    id: 1,
    text: "Question 1",
  },
  {
    id: 2,
    text: "Question 2",
  },
  {
    id: 3,
    text: "Question 3",
  },
  {
    id: 4,
    text: "Question 4",
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
