#!/usr/bin/env bash
set -Eeuo pipefail

# Repeatable release deploy for dinpanel.
# Usage:
#   common/deploy.sh <deploy_env>
# where deploy_env is typically: prod | test

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <deploy_env>" >&2
  exit 1
fi

DEPLOY_ENV_RAW="${1}"
DEPLOY_ENV_NORMALIZED="${DEPLOY_ENV_RAW,,}"

APP_NAME="${APP_NAME:-dinpanel}"
if [[ "${DEPLOY_ENV_NORMALIZED}" == "prod" ]]; then
  APP_DOMAIN="dinpanel.com"
else
  APP_DOMAIN="${DEPLOY_ENV_NORMALIZED}.dinpanel.com"
fi
APP_USER="${APP_USER:-dinpanel}"
APP_GROUP="${APP_GROUP:-www-data}"
APP_BASE_DIR="${APP_BASE_DIR:-/var/www/${APP_NAME}}"
APP_REPO_URL="${APP_REPO_URL:-https://github.com/vespy-pg/DINPanel.git}"
GIT_REF="${GIT_REF:-main}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
APP_RUNTIME_ENV="${APP_RUNTIME_ENV:-prod}"

PHP_VERSION="${PHP_VERSION:-auto}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"
APACHE_SERVICE="${APACHE_SERVICE:-apache2}"

RUN_MIGRATIONS="${RUN_MIGRATIONS:-0}" # 1 = run doctrine:migrations:migrate
ENABLE_WEB_BUILD="${ENABLE_WEB_BUILD:-0}"
ALLOW_MISSING_EXTENSIONS="${ALLOW_MISSING_EXTENSIONS:-0}" # 1 = pre-prod fallback

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if [[ -z "${APP_REPO_URL}" ]]; then
  echo "APP_REPO_URL is required." >&2
  exit 1
fi

if [[ ! -d "${APP_BASE_DIR}/shared" ]]; then
  echo "Missing ${APP_BASE_DIR}/shared. Run init script first." >&2
  exit 1
fi

if [[ ! -f "${APP_BASE_DIR}/shared/env/.env.local" ]]; then
  echo "Missing ${APP_BASE_DIR}/shared/env/.env.local. Run init script first." >&2
  exit 1
fi

resolve_php_version() {
  local requested="$1"
  local candidates=(8.4 8.3 8.2 8.1 8.0)
  local detected=""
  local candidate=""

  if [[ "${requested}" != "auto" ]]; then
    if command -v "php${requested}" >/dev/null 2>&1; then
      echo "${requested}"
      return 0
    fi
    echo "Requested PHP_VERSION=${requested}, but binary php${requested} is unavailable." >&2
    echo "Set PHP_VERSION=auto or install php${requested}." >&2
    return 1
  fi

  for candidate in "${candidates[@]}"; do
    if command -v "php${candidate}" >/dev/null 2>&1; then
      detected="${candidate}"
      break
    fi
  done

  if [[ -z "${detected}" ]]; then
    echo "Unable to detect an installed PHP CLI binary (checked: ${candidates[*]})." >&2
    echo "Set PHP_VERSION explicitly and ensure php<version> is installed." >&2
    return 1
  fi

  echo "${detected}"
}

PHP_VERSION="$(resolve_php_version "${PHP_VERSION}")"
PHP_BIN="php${PHP_VERSION}"
if [[ -z "${PHP_FPM_SERVICE}" ]]; then
  PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
fi

echo "Using PHP version ${PHP_VERSION}"

REQUIRED_EXTENSIONS=(curl dom iconv libxml pdo simplexml bcmath http)
MISSING_EXTENSIONS=()
for ext in "${REQUIRED_EXTENSIONS[@]}"; do
  if ! "${PHP_BIN}" -m | awk '{print tolower($0)}' | grep -q "^${ext}$"; then
    MISSING_EXTENSIONS+=("${ext}")
  fi
done

if (( ${#MISSING_EXTENSIONS[@]} > 0 )); then
  if [[ "${ALLOW_MISSING_EXTENSIONS}" != "1" ]]; then
    echo "Missing required PHP extensions for php${PHP_VERSION}: ${MISSING_EXTENSIONS[*]}" >&2
    exit 1
  fi
  echo "Warning: missing PHP extensions for php${PHP_VERSION}: ${MISSING_EXTENSIONS[*]}"
  echo "Warning: continuing because ALLOW_MISSING_EXTENSIONS=1 (temporary pre-prod mode)."
fi

TIMESTAMP="$(date +%Y%m%d%H%M%S)"
NEW_RELEASE="${APP_BASE_DIR}/releases/${TIMESTAMP}"

echo "Creating release directory: ${NEW_RELEASE}"
mkdir -p "${NEW_RELEASE}"
chown -R "${APP_USER}:${APP_GROUP}" "${APP_BASE_DIR}"

echo "Fetching source (${GIT_REF})..."
su -s /bin/bash - "${APP_USER}" -c "git clone '${APP_REPO_URL}' '${NEW_RELEASE}'"
su -s /bin/bash - "${APP_USER}" -c "cd '${NEW_RELEASE}' && git fetch --tags origin '${GIT_REF}' && git checkout -q FETCH_HEAD"

echo "Linking shared files/directories..."
mkdir -p "${APP_BASE_DIR}/shared"/{env,var/log,var/cache,public/uploads}
rm -f "${NEW_RELEASE}/env/.env.local"
ln -s "${APP_BASE_DIR}/shared/env/.env.local" "${NEW_RELEASE}/env/.env.local"

rm -rf "${NEW_RELEASE}/var/log" "${NEW_RELEASE}/var/cache"
ln -s "${APP_BASE_DIR}/shared/var/log" "${NEW_RELEASE}/var/log"
ln -s "${APP_BASE_DIR}/shared/var/cache" "${NEW_RELEASE}/var/cache"

mkdir -p "${NEW_RELEASE}/public"
if [[ -e "${NEW_RELEASE}/public/uploads" && ! -L "${NEW_RELEASE}/public/uploads" ]]; then
  rm -rf "${NEW_RELEASE}/public/uploads"
fi
ln -sfn "${APP_BASE_DIR}/shared/public/uploads" "${NEW_RELEASE}/public/uploads"

echo "Installing composer dependencies..."
COMPOSER_INSTALL_FLAGS="--no-dev --optimize-autoloader --classmap-authoritative"
if [[ "${ALLOW_MISSING_EXTENSIONS}" == "1" ]] && (( ${#MISSING_EXTENSIONS[@]} > 0 )); then
  for ext in "${MISSING_EXTENSIONS[@]}"; do
    COMPOSER_INSTALL_FLAGS+=" --ignore-platform-req=ext-${ext}"
  done
fi
su -s /bin/bash - "${APP_USER}" -c "cd '${NEW_RELEASE}' && composer install ${COMPOSER_INSTALL_FLAGS}"

if [[ "${ENABLE_WEB_BUILD}" == "1" ]]; then
  echo "Building SPA..."
  su -s /bin/bash - "${APP_USER}" -c "cd '${NEW_RELEASE}' && npm ci && npm run web:build"
fi

if [[ "${RUN_MIGRATIONS}" == "1" ]]; then
  echo "Running Doctrine migrations..."
  su -s /bin/bash - "${APP_USER}" -c "cd '${NEW_RELEASE}' && ${PHP_BIN} bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration --env=${APP_RUNTIME_ENV}"
fi

echo "Warming Symfony cache..."
su -s /bin/bash - "${APP_USER}" -c "cd '${NEW_RELEASE}' && ${PHP_BIN} bin/console cache:clear --env=${APP_RUNTIME_ENV} --no-debug"

echo "Sanity checks..."
su -s /bin/bash - "${APP_USER}" -c "cd '${NEW_RELEASE}' && ${PHP_BIN} bin/console lint:container --env=${APP_RUNTIME_ENV}"
su -s /bin/bash - "${APP_USER}" -c "cd '${NEW_RELEASE}' && ${PHP_BIN} bin/console about --env=${APP_RUNTIME_ENV} >/dev/null"

echo "Switching current symlink..."
ln -sfn "${NEW_RELEASE}" "${APP_BASE_DIR}/current"
chown -h "${APP_USER}:${APP_GROUP}" "${APP_BASE_DIR}/current"

echo "Reloading services..."
apache2ctl configtest
systemctl reload "${PHP_FPM_SERVICE}"
systemctl reload "${APACHE_SERVICE}"

echo "Cleaning up old releases (keep ${KEEP_RELEASES})..."
mapfile -t RELEASES < <(ls -1dt "${APP_BASE_DIR}/releases"/* 2>/dev/null || true)
if (( ${#RELEASES[@]} > KEEP_RELEASES )); then
  for old in "${RELEASES[@]:KEEP_RELEASES}"; do
    rm -rf "${old}"
  done
fi

CURRENT_TARGET="$(readlink -f "${APP_BASE_DIR}/current")"
if [[ -n "${APP_DOMAIN}" ]]; then
  echo "Smoke test URL: http://${APP_DOMAIN}/"
fi
echo "Deploy complete. Current release: ${CURRENT_TARGET}"
