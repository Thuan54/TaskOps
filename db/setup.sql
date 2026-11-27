\set ON_ERROR_STOP on
\getenv app_password TASKOPS_APP_PASSWORD

SELECT format('CREATE ROLE taskops_app LOGIN PASSWORD %L', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'taskops_app')
\gexec

SELECT format(
    'ALTER ROLE taskops_app WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L',
    :'app_password'
)
\gexec

SELECT 'CREATE DATABASE taskops'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'taskops')
\gexec

REVOKE ALL ON DATABASE taskops FROM PUBLIC;
GRANT CONNECT ON DATABASE taskops TO taskops_app;
\connect taskops

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO taskops_app;

CREATE TABLE IF NOT EXISTS public.tasks (
    id BIGSERIAL PRIMARY KEY,
    text VARCHAR(200) NOT NULL CHECK (btrim(text) <> ''),
    completed BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.tasks TO taskops_app;
GRANT USAGE, SELECT ON SEQUENCE public.tasks_id_seq TO taskops_app;
