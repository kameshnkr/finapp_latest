/**
 * Applies a single SQL migration file to the database.
 *
 * Usage:
 *   tsx src/scripts/migrate.ts <path-to-sql-file>
 *
 * Example:
 *   tsx src/scripts/migrate.ts data_model/migration_category_type.sql
 */
import "dotenv/config";
import { readFileSync } from "fs";
import pg from "pg";

const { Pool } = pg;

const file = process.argv[2];
if (!file) {
  console.error("Usage: tsx src/scripts/migrate.ts <path-to-sql-file>");
  process.exit(1);
}

const sql = readFileSync(file, "utf-8");

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

try {
  await pool.query(sql);
  console.log(`✓ Migration applied: ${file}`);
} catch (err: unknown) {
  const msg = err instanceof Error ? err.message : String(err);
  console.error(`✗ Migration failed: ${msg}`);
  process.exit(1);
} finally {
  await pool.end();
}
