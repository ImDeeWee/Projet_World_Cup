import pg from "pg";
import dotenv from "dotenv";
dotenv.config();

const pool = new pg.Pool({
  host:     process.env.PGHOST,
  port:     process.env.PGPORT,
  user:     process.env.PGUSER,
  password: process.env.PGPASSWORD,
  database: process.env.PGDATABASE,
});

export const query = (text, params) => pool.query(text, params);
