#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(cd "${SCRIPT_DIR}/../common" && pwd)"

export APP_BASE_DIR="${APP_BASE_DIR:-/var/www/dinpanel-test}"
export APP_DOMAIN="${APP_DOMAIN:-test.dinpanel.com}"

exec "${COMMON_DIR}/fix-pwa-assets.sh"
