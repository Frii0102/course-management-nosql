\set ON_ERROR_STOP on
BEGIN;
\ir 01_schema.sql
\ir 02_functions.sql
\ir 07_seed.sql
\ir 03_triggers.sql
\ir 04_views.sql
\ir 05_procedures.sql
\ir 06_indexes.sql
COMMIT;
