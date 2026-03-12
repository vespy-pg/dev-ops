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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ENV_DIR="${SCRIPT_DIR}/../${DEPLOY_ENV_NORMALIZED}"

APP_NAME="${APP_NAME:-dinpanel}"
if [[ "${DEPLOY_ENV_NORMALIZED}" == "prod" ]]; then
  APP_DOMAIN="dinpanel.com"
else
  APP_DOMAIN="${DEPLOY_ENV_NORMALIZED}.dinpanel.com"
fi
APP_USER="${APP_USER:-pawel}"
APP_GROUP="${APP_GROUP:-www-data}"
APP_BASE_DIR="${APP_BASE_DIR:-/var/www/${APP_NAME}}"
APP_REPO_URL="${APP_REPO_URL:-git@github.com:vespy-pg/DINPanel.git}"
GIT_REF="${GIT_REF:-main}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
APP_RUNTIME_ENV="${APP_RUNTIME_ENV:-${DEPLOY_ENV_NORMALIZED}}"

PHP_VERSION="${PHP_VERSION:-auto}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"
APACHE_SERVICE="${APACHE_SERVICE:-apache2}"

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

if [[ ! -d "${OPS_ENV_DIR}" ]]; then
  echo "Missing ops env directory: ${OPS_ENV_DIR}. Run init script first." >&2
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

extension_is_loaded() {
  local ext="$1"
  "${PHP_BIN}" -m | awk '{print tolower($0)}' | grep -q "^${ext}$"
}

collect_required_project_extensions() {
  local project_dir="$1"
  php -r '
    $dir = $argv[1];
    $exts = [];
    $add = static function ($req) use (&$exts): void {
      if (!is_array($req)) {
        return;
      }
      foreach ($req as $name => $_constraint) {
        if (is_string($name) && str_starts_with($name, "ext-")) {
          $ext = strtolower(substr($name, 4));
          if ($ext !== "") {
            $exts[$ext] = true;
          }
        }
      }
    };
    foreach (["composer.json", "composer.lock"] as $file) {
      $path = $dir . "/" . $file;
      if (!is_file($path)) {
        continue;
      }
      $data = json_decode((string) file_get_contents($path), true);
      if (!is_array($data)) {
        continue;
      }
      $add($data["require"] ?? null);
      $add($data["platform"] ?? null);
      if (isset($data["packages"]) && is_array($data["packages"])) {
        foreach ($data["packages"] as $pkg) {
          if (is_array($pkg)) {
            $add($pkg["require"] ?? null);
          }
        }
      }
    }
    ksort($exts);
    echo implode(PHP_EOL, array_keys($exts));
  ' "${project_dir}"
}

validate_required_ops_env_files() {
  local release_dir="$1"
  local release_env_dir="${release_dir}/env"
  local example_file=""
  local required_target=""
  local missing=()
  local -a example_paths=()

  shopt -s dotglob nullglob
  example_paths=("${release_env_dir}"/*.env.example)
  shopt -u dotglob nullglob

  for example_file in "${example_paths[@]}"; do
    required_target="$(basename "${example_file}")"
    required_target="${required_target%.example}"
    if [[ ! -f "${OPS_ENV_DIR}/${required_target}" ]]; then
      missing+=("${required_target}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "Missing env files in ${OPS_ENV_DIR}: ${missing[*]}" >&2
    exit 1
  fi
}

copy_ops_env_to_release() {
  local release_dir="$1"
  local release_env_dir="${release_dir}/env"
  local ops_env_file=""
  local env_example=""
  local env_target=""
  local -a ops_env_paths=()

  mkdir -p "${release_env_dir}"
  shopt -s dotglob nullglob
  ops_env_paths=("${OPS_ENV_DIR}"/*.env)
  shopt -u dotglob nullglob

  if (( ${#ops_env_paths[@]} == 0 )); then
    echo "No ops env files (*.env) found in ${OPS_ENV_DIR}" >&2
    exit 1
  fi

  for ops_env_file in "${ops_env_paths[@]}"; do
    install -m 600 -o "${APP_USER}" -g "${APP_GROUP}" "${ops_env_file}" "${release_env_dir}/$(basename "${ops_env_file}")"
  done

  while IFS= read -r env_example; do
    env_target="${env_example%.example}"
    if [[ ! -f "${release_env_dir}/${env_target}" ]]; then
      echo "Expected env file missing in release: ${release_env_dir}/${env_target}" >&2
      exit 1
    fi
    if ! su -s /bin/bash - "${APP_USER}" -c "test -r '${release_env_dir}/${env_target}'"; then
      echo "Env file is not readable by ${APP_USER}: ${release_env_dir}/${env_target}" >&2
      exit 1
    fi
  done < <(find "${release_env_dir}" -maxdepth 1 -type f -name "*.env.example" -printf "%f\n" | sort)
}

PHP_VERSION="$(resolve_php_version "${PHP_VERSION}")"
PHP_BIN="php${PHP_VERSION}"
if [[ -z "${PHP_FPM_SERVICE}" ]]; then
  PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
fi

echo "Using PHP version ${PHP_VERSION}"

REQUIRED_EXTENSIONS=(curl dom gd iconv libxml pdo simplexml bcmath raphf http)
MISSING_EXTENSIONS=()
for ext in "${REQUIRED_EXTENSIONS[@]}"; do
  if ! extension_is_loaded "${ext}"; then
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

echo "Validating repository access for ${APP_USER}..."
if ! su -s /bin/bash - "${APP_USER}" -c "export GIT_TERMINAL_PROMPT=0; git ls-remote --exit-code '${APP_REPO_URL}' HEAD >/dev/null 2>&1"; then
  echo "Cannot access APP_REPO_URL as ${APP_USER}: ${APP_REPO_URL}" >&2
  exit 1
fi

echo "Fetching source (${GIT_REF})..."
su -s /bin/bash - "${APP_USER}" -c "export GIT_TERMINAL_PROMPT=0; git clone '${APP_REPO_URL}' '${NEW_RELEASE}'"
su -s /bin/bash - "${APP_USER}" -c "export GIT_TERMINAL_PROMPT=0; cd '${NEW_RELEASE}' && git fetch --tags origin '${GIT_REF}' && git checkout -q FETCH_HEAD"

validate_required_ops_env_files "${NEW_RELEASE}"
copy_ops_env_to_release "${NEW_RELEASE}"

echo "Checking PHP extensions required by composer files..."
mapfile -t PROJECT_REQUIRED_EXTENSIONS < <(collect_required_project_extensions "${NEW_RELEASE}" | sed '/^$/d')
if (( ${#PROJECT_REQUIRED_EXTENSIONS[@]} > 0 )); then
  MISSING_EXTENSIONS=()
  for ext in "${PROJECT_REQUIRED_EXTENSIONS[@]}"; do
    if ! extension_is_loaded "${ext}"; then
      MISSING_EXTENSIONS+=("${ext}")
    fi
  done
  if (( ${#MISSING_EXTENSIONS[@]} > 0 )); then
    if [[ "${ALLOW_MISSING_EXTENSIONS}" != "1" ]]; then
      echo "Missing project-required PHP extensions for php${PHP_VERSION}: ${MISSING_EXTENSIONS[*]}" >&2
      exit 1
    fi
    echo "Warning: missing project-required PHP extensions for php${PHP_VERSION}: ${MISSING_EXTENSIONS[*]}"
    echo "Warning: continuing because ALLOW_MISSING_EXTENSIONS=1 (temporary pre-prod mode)."
  fi
fi

echo "Linking shared files/directories..."
mkdir -p "${APP_BASE_DIR}/shared"/{var/log,var/cache,public/uploads}
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

echo "Running Doctrine migrations..."
su -s /bin/bash - "${APP_USER}" -c "cd '${NEW_RELEASE}' && ${PHP_BIN} bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration --env=${APP_RUNTIME_ENV}"

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
