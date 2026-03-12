#!/usr/bin/env bash
set -Eeuo pipefail

DB_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.api.env"

if [[ ! -f "${DB_FILE}" ]]; then
  echo "Missing env file: ${DB_FILE}" >&2
  exit 1
fi

read_env() {
  local key="$1"
  sed -n "s/^${key}=//p" "${DB_FILE}" | head -n1
}

DB_NAME="$(read_env DB_NAME)"
DB_USER="$(read_env DB_USER)"
DB_PASSWORD="$(read_env DB_PASSWORD)"

if [[ -z "${DB_NAME}" || -z "${DB_USER}" || -z "${DB_PASSWORD}" ]]; then
  echo "DB_NAME/DB_USER/DB_PASSWORD must be set in ${DB_FILE}" >&2
  exit 1
fi

echo "Using DB config from: ${DB_FILE}"
echo "DB_NAME=${DB_NAME}"
echo "DB_USER=${DB_USER}"

sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -v db_name="${DB_NAME}" -v db_user="${DB_USER}" -v db_password="${DB_PASSWORD}" <<'SQL'
SELECT format(
  'ALTER ROLE %I LOGIN PASSWORD %L',
  :'db_user',
  :'db_password'
)
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user')
\gexec

SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L',
  :'db_user',
  :'db_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user')
\gexec

SELECT format(
  'GRANT CONNECT, TEMPORARY, CREATE ON DATABASE %I TO %I',
  :'db_name',
  :'db_user'
)
\gexec
SQL

echo "Testing DB login..."
PGPASSWORD="${DB_PASSWORD}" psql -h 127.0.0.1 -p 5432 -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -c 'select current_user, current_database();'

echo "Done. Now run:"
echo "  sudo ./scripts/deploy/dinpanel/prod/deploy.sh"
