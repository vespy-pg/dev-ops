#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.api.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing env file: ${ENV_FILE}" >&2
  exit 1
fi

read_env() {
  local key="$1"
  sed -n "s/^${key}=//p" "${ENV_FILE}" | head -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

DB_NAME="$(read_env DB_NAME)"
DB_USER="$(read_env DB_USER)"
if [[ -z "${DB_USER}" ]]; then
  DB_USER="$(read_env DB_USERNAME)"
fi

if [[ -z "${DB_NAME}" || -z "${DB_USER}" ]]; then
  echo "DB_NAME and DB_USER/DB_USERNAME must be set in ${ENV_FILE}" >&2
  exit 1
fi

echo "Granting schema permissions on database '${DB_NAME}' to role '${DB_USER}'..."
sudo -u postgres psql -d "${DB_NAME}" -v ON_ERROR_STOP=1 -v db_user="${DB_USER}" <<'SQL'
SELECT format('GRANT USAGE, CREATE ON SCHEMA public TO %I', :'db_user') \gexec
SQL

echo "Done. Re-run deploy:"
echo "  sudo ./scripts/deploy/dinpanel/prod/deploy.sh"
