# TaskOps app

The app is a small React and Tailwind CSS todo list served by an Express API
and backed by PostgreSQL.

## Set up PostgreSQL

Install PostgreSQL and make sure its service is running. From the repository
root, run `bash db/setup.sh` as a PostgreSQL administrator. The script prompts
for the `taskops_app` role password (or reads `TASKOPS_APP_PASSWORD` from the
environment) and creates the `taskops` database, the restricted role, and the
`tasks` table. The role receives only table CRUD and the sequence permissions
needed for inserts.

For local development, set `DB_PASSWORD` to the password used during setup.
Optional connection settings are `DB_HOST`, `DB_PORT`, `DB_NAME`, and `DB_USER`;
they default to `127.0.0.1`, `5432`, `taskops`, and `taskops_app`.

## Run locally

```sh
npm install
npm run dev
```

Open the Vite URL printed in the terminal. The Vite development server proxies
`/api` requests to Express on `127.0.0.1:5000`.

## Build and run

```sh
npm run build
npm start
```

The production server serves the generated frontend and API on
`127.0.0.1:5000`. Keep `DB_PASSWORD` in an environment file or secret manager,
not in source control.
