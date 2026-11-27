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

## Run under systemd

From the repository root, build the app with `cd app && npm run build`, then
deploy `dist/`, `static/`, `package.json`, and production dependencies to
`/opt/taskops/app`. Create the unprivileged service account and protected
environment file:

```sh
sudo useradd --system --user-group --no-create-home \
  --home-dir /nonexistent --shell /usr/sbin/nologin taskops
sudo install -d -o root -g taskops -m 0750 /etc/taskops
sudo install -o root -g taskops -m 0640 \
  toolkit/conf/taskops.env.example /etc/taskops/taskops.env
sudoedit /etc/taskops/taskops.env
sudo chown root:taskops /opt/taskops
sudo chmod 0750 /opt/taskops
sudo chown -R root:taskops /opt/taskops/app
sudo chmod -R u=rwX,g=rX,o= /opt/taskops/app
```

Set `DB_PASSWORD` to the password assigned to `taskops_app`. Ensure the app
files and all parent directories are readable/traversable by `taskops` but not
writable by that account. The environment directory/file are `root:taskops`
with modes `0750`/`0640`. Install and start the service:

```sh
sudo install -o root -g root -m 0644 \
  toolkit/systemd/taskops.service /etc/systemd/system/taskops.service
sudo systemctl daemon-reload
sudo systemctl enable --now taskops.service
```

The service binds only to localhost, restarts on process failure, and writes
stdout/stderr to journald (`journalctl -u taskops.service`). `GET /api/health`
returns HTTP 200 when PostgreSQL is reachable and HTTP 503 with separate
backend/database states when it is not.

The health response shape is `{"status":"ok","backend":"ok","database":"ok"}`
on success. If PostgreSQL cannot be queried, it returns
`{"status":"degraded","backend":"ok","database":"unavailable"}` with HTTP 503;
connection details are logged locally, not returned to clients.
