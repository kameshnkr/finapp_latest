import pg from "pg";
import { env } from "../config/env.js";

// OID 1082 = DATE. By default pg parses DATE into a JS Date using local midnight,
// which causes an off-by-one day error in timezones east of UTC (e.g. IST UTC+5:30).
// Return the raw "YYYY-MM-DD" string instead so callers never need timezone math.
pg.types.setTypeParser(1082, (val: string) => val);

export const pool = new pg.Pool({ connectionString: env.databaseUrl });
