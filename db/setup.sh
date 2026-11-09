#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TASKOPS_APP_PASSWORD:-}" ]]; then
    if [[ -t 0 ]]; then
        read -r -s -p "Password for PostgreSQL role taskops_app: " TASKOPS_APP_PASSWORD
        printf '\n'
        export TASKOPS_APP_PASSWORD
    else
        printf 'Set TASKOPS_APP_PASSWORD or run this script interactively.\n' >&2
        exit 1
    fi
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec psql --set=ON_ERROR_STOP=1 --dbname="${PGDATABASE:-postgres}" --file="$script_dir/setup.sql"
