#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [git_ref]" >&2
  exit 1
fi

if [[ $# -eq 1 && -z "${1}" ]]; then
  echo "git_ref cannot be empty." >&2
  exit 1
fi

export GIT_REF="${1:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(cd "${SCRIPT_DIR}/../common" && pwd)"

export APP_NAME="${APP_NAME:-dinpanel-test}"
export APP_BASE_DIR="${APP_BASE_DIR:-/var/www/${APP_NAME}}"
export APP_RUNTIME_ENV="${APP_RUNTIME_ENV:-prod}"
export FORCE_HTTPS_REDIRECT="${FORCE_HTTPS_REDIRECT:-1}"
export ENABLE_TLS_AUTOMATION="${ENABLE_TLS_AUTOMATION:-1}"
export INSTALL_DEV_DEPENDENCIES="${INSTALL_DEV_DEPENDENCIES:-1}"

if [[ "${APP_NAME}" == "dinpanel" || "${APP_BASE_DIR%/}" == "/var/www/dinpanel" ]]; then
  echo "Refusing to run test deploy against production app target." >&2
  echo "APP_NAME=${APP_NAME}" >&2
  echo "APP_BASE_DIR=${APP_BASE_DIR}" >&2
  exit 1
fi

exec "${COMMON_DIR}/deploy.sh" test
