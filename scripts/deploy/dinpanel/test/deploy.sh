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

exec "${COMMON_DIR}/deploy.sh" test
