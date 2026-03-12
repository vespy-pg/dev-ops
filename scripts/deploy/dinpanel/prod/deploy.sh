#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 0 ]]; then
  echo "This script does not accept arguments." >&2
  echo "Use environment variables for overrides (e.g. APP_REPO_URL, GIT_REF)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(cd "${SCRIPT_DIR}/../common" && pwd)"

exec "${COMMON_DIR}/deploy.sh" prod
