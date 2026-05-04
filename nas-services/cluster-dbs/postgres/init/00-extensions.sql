-- Runs once on first boot (only when data dir is empty).
-- Enables extensions on the default 'postgres' database.
-- For new databases, run CREATE EXTENSION manually after creation.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
