#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 0 ]]; then
  echo "This script does not accept arguments." >&2
  echo "Use environment variables for overrides (e.g. APP_REPO_URL, GIT_REF, DB_*)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(cd "${SCRIPT_DIR}/../common" && pwd)"

export APP_NAME="${APP_NAME:-dinpanel-test}"
export APP_BASE_DIR="${APP_BASE_DIR:-/var/www/${APP_NAME}}"
export APP_RUNTIME_ENV="${APP_RUNTIME_ENV:-prod}"
export NON_INTERACTIVE="${NON_INTERACTIVE:-1}"
export ENABLE_WEB_BUILD="${ENABLE_WEB_BUILD:-1}"
export FORCE_HTTPS_REDIRECT="${FORCE_HTTPS_REDIRECT:-1}"
export ENABLE_TLS_AUTOMATION="${ENABLE_TLS_AUTOMATION:-1}"
export TLS_DOMAINS="${TLS_DOMAINS:-test.dinpanel.com api.test.dinpanel.com}"
export INSTALL_DEV_DEPENDENCIES="${INSTALL_DEV_DEPENDENCIES:-1}"

if [[ "${APP_NAME}" == "dinpanel" || "${APP_BASE_DIR%/}" == "/var/www/dinpanel" ]]; then
  echo "Refusing to run test init against production app target." >&2
  echo "APP_NAME=${APP_NAME}" >&2
  echo "APP_BASE_DIR=${APP_BASE_DIR}" >&2
  exit 1
fi

exec "${COMMON_DIR}/init.sh" test
