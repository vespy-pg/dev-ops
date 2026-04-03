#!/usr/bin/env bash
set -Eeuo pipefail

# One-time initialization for dinpanel.
# Usage:
#   common/init.sh <deploy_env>
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
API_DOMAIN="${API_DOMAIN:-api.${APP_DOMAIN}}"
APP_USER="${APP_USER:-pawel}"
APP_GROUP="${APP_GROUP:-www-data}"
APP_BASE_DIR="${APP_BASE_DIR:-/var/www/${APP_NAME}}"
APP_REPO_URL="${APP_REPO_URL:-git@github.com:vespy-pg/DINPanel.git}"
GIT_REF="${GIT_REF:-main}"
APP_RUNTIME_ENV="${APP_RUNTIME_ENV:-${DEPLOY_ENV_NORMALIZED}}"

PHP_VERSION="${PHP_VERSION:-auto}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"
PHP_FPM_SOCK="${PHP_FPM_SOCK:-}"
APACHE_SERVICE="${APACHE_SERVICE:-apache2}"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-dinpanel}"
DB_USER="${DB_USER:-${DB_USERNAME:-dinpanel_user}}"
DB_USERNAME="${DB_USERNAME:-${DB_USER}}"
DB_ENV_FILE="${DB_ENV_FILE:-.api.env}"
DB_ADMIN_DB="${DB_ADMIN_DB:-postgres}"
DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-}"
DB_OWNER="${DB_OWNER:-${DB_ADMIN_USER}}"
DB_SCHEMA_NAME="${DB_SCHEMA_NAME:-app}"
DB_SCHEMA_OWNER="${DB_SCHEMA_OWNER:-${DB_ADMIN_USER}}"

ENABLE_DB_BOOTSTRAP="${ENABLE_DB_BOOTSTRAP:-1}" # 1 = create db/user and run sql/[!0_]*
ENABLE_WEB_BUILD="${ENABLE_WEB_BUILD:-0}"       # 1 = install node/npm and build web
ALLOW_MISSING_EXTENSIONS="${ALLOW_MISSING_EXTENSIONS:-0}" # 1 = pre-prod fallback
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"         # 1 = no prompts
SHARED_PUBLIC_DIRS="${SHARED_PUBLIC_DIRS:-uploads media}"
NODE_BIN_DIR="${NODE_BIN_DIR:-/home/${APP_USER}/.nvm/versions/node/v24.12.0/bin}"
REQUIRED_NODE_VERSION="${REQUIRED_NODE_VERSION:-24.12.0}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if [[ -z "${APP_REPO_URL}" ]]; then
  echo "APP_REPO_URL is required." >&2
  exit 1
fi

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${VERSION_ID:-}" == "18.04" ]]; then
    echo "Warning: Ubuntu 18.04 is EOL. Acceptable for temporary pre-prod, not for real production."
  fi
fi

normalize_name_with_env_suffix() {
  local base="$1"
  local suffix="_${DEPLOY_ENV_NORMALIZED}"
  if [[ "${base}" == *"${suffix}" ]]; then
    base="${base%${suffix}}"
  fi
  echo "${base}${suffix}"
}

is_safe_sql_identifier() {
  local value="$1"
  [[ "${value}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped
  escaped="$(escape_sed_replacement "${value}")"
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s/^${key}=.*/${key}=${escaped}/" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

read_env_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "${file}" | head -n1
}

strip_wrapping_quotes() {
  local value="$1"
  if [[ "${value}" =~ ^\".*\"$ ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "${value}" =~ ^\'.*\'$ ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "${value}"
}

prompt_overwrite_default_no() {
  local target="$1"
  if [[ "${NON_INTERACTIVE}" == "1" ]]; then
    return 1
  fi
  local answer
  read -r -p "File ${target} already exists. Overwrite? [y/N]: " answer
  [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

resolve_php_version() {
  local requested="$1"
  local candidates=(8.4 8.3 8.2 8.1 8.0)
  local detected=""
  local candidate=""

  if [[ "${requested}" != "auto" ]]; then
    if apt-cache show "php${requested}-cli" >/dev/null 2>&1 && apt-cache show "php${requested}-fpm" >/dev/null 2>&1; then
      echo "${requested}"
      return 0
    fi
    echo "Requested PHP_VERSION=${requested}, but php${requested}-cli/php${requested}-fpm are unavailable in apt." >&2
    echo "Either set PHP_VERSION=auto or enable a repository that provides PHP ${requested} packages." >&2
    return 1
  fi

  for candidate in "${candidates[@]}"; do
    if apt-cache show "php${candidate}-cli" >/dev/null 2>&1 && apt-cache show "php${candidate}-fpm" >/dev/null 2>&1; then
      detected="${candidate}"
      break
    fi
  done

  if [[ -z "${detected}" ]]; then
    echo "Unable to detect an installable PHP version from apt (checked: ${candidates[*]})." >&2
    echo "Set PHP_VERSION explicitly and ensure apt repositories provide php<version>-cli and php<version>-fpm." >&2
    return 1
  fi

  echo "${detected}"
}

require_php_pkg() {
  local pkg="$1"
  if ! apt-cache show "${pkg}" >/dev/null 2>&1; then
    echo "Required package not found: ${pkg}" >&2
    echo "This usually means your apt PHP repository does not provide PHP ${PHP_VERSION} extensions." >&2
    return 1
  fi
  apt-get install -y "${pkg}"
}

extension_is_loaded() {
  local ext="$1"
  "php${PHP_VERSION}" -m | awk '{print tolower($0)}' | grep -q "^${ext}$"
}

php_pkg_suffix_for_extension() {
  local ext="$1"
  case "${ext}" in
    pdo_pgsql|pgsql) echo "pgsql" ;;
    dom|simplexml|xmlreader|xmlwriter) echo "xml" ;;
    *) echo "${ext}" ;;
  esac
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

build_db_password() {
  openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-' | cut -c1-48
}

prepare_ops_env_files() {
  local release_dir="$1"
  local release_env_dir="${release_dir}/env"
  local gitignore_file="${OPS_ENV_DIR}/.gitignore"
  local example_name=""
  local target_name=""
  local source_file=""
  local target_file=""
  local -a example_paths=()

  mkdir -p "${OPS_ENV_DIR}"
  touch "${gitignore_file}"
  if ! grep -qxF "*.env" "${gitignore_file}"; then
    echo "*.env" >> "${gitignore_file}"
  fi

  shopt -s dotglob nullglob
  example_paths=("${release_env_dir}"/*.env.example)
  shopt -u dotglob nullglob

  if (( ${#example_paths[@]} == 0 )); then
    echo "No *.env.example files found in ${release_env_dir}" >&2
    exit 1
  fi

  for source_file in "${example_paths[@]}"; do
    example_name="$(basename "${source_file}")"
    target_name="${example_name%.example}"
    target_file="${OPS_ENV_DIR}/${target_name}"

    if [[ -f "${target_file}" ]] && ! prompt_overwrite_default_no "${target_file}"; then
      echo "Keeping existing ${target_file}"
    else
      cp "${source_file}" "${target_file}"
      echo "Prepared ${target_file}"
    fi
    chmod 600 "${target_file}"
    chown "${APP_USER}:${APP_GROUP}" "${target_file}"
  done
}

bootstrap_database() {
  local release_dir="$1"
  local ops_main_env="${OPS_ENV_DIR}/${DB_ENV_FILE}"
  local sql_file=""
  local sql_path=""
  local run_sql_path=""
  local temp_sql=""
  local -a sql_files=()
  local -a phase1_sql_files=()
  local -a phase2_sql_files=()
  local -a ops_env_files=()
  local db_admin_psql_base=()

  if [[ ! -f "${ops_main_env}" ]]; then
    if [[ -f "${OPS_ENV_DIR}/.env" ]]; then
      ops_main_env="${OPS_ENV_DIR}/.env"
    elif [[ -f "${OPS_ENV_DIR}/.api.env" ]]; then
      ops_main_env="${OPS_ENV_DIR}/.api.env"
    else
      shopt -s dotglob nullglob
      ops_env_files=("${OPS_ENV_DIR}"/*.env)
      shopt -u dotglob nullglob
      if (( ${#ops_env_files[@]} > 0 )); then
        ops_main_env="${ops_env_files[0]}"
      fi
    fi
  fi

  if [[ ! -f "${ops_main_env}" ]]; then
    echo "Missing DB env target (${OPS_ENV_DIR}/${DB_ENV_FILE}) and no fallback *.env found. Cannot bootstrap database." >&2
    exit 1
  fi

  echo "Using DB env file: ${ops_main_env}"

  if [[ -z "${DB_USER}" ]]; then
    DB_USER="$(strip_wrapping_quotes "$(read_env_value "${ops_main_env}" "DB_USER")")"
  fi
  if [[ -z "${DB_USER}" ]]; then
    DB_USER="$(strip_wrapping_quotes "$(read_env_value "${ops_main_env}" "DB_USERNAME")")"
  fi
  DB_USER="${DB_USER:-dinpanel_user}"

  DB_NAME="$(normalize_name_with_env_suffix "${DB_NAME}")"
  DB_USER="$(normalize_name_with_env_suffix "${DB_USER}")"
  DB_USERNAME="${DB_USER}"
  DB_PASSWORD="$(build_db_password)"

  if ! is_safe_sql_identifier "${DB_NAME}" || ! is_safe_sql_identifier "${DB_USER}"; then
    echo "Unsafe DB_NAME or DB_USER after suffix normalization." >&2
    echo "DB_NAME=${DB_NAME} DB_USER=${DB_USER}" >&2
    exit 1
  fi

  set_env_value "${ops_main_env}" "APP_ENV" "${APP_RUNTIME_ENV}"
  set_env_value "${ops_main_env}" "DB_HOST" "${DB_HOST}"
  set_env_value "${ops_main_env}" "DB_PORT" "${DB_PORT}"
  set_env_value "${ops_main_env}" "DB_NAME" "${DB_NAME}"
  set_env_value "${ops_main_env}" "DB_USER" "${DB_USER}"
  set_env_value "${ops_main_env}" "DB_USERNAME" "${DB_USER}"
  set_env_value "${ops_main_env}" "DB_PASSWORD" "${DB_PASSWORD}"
  set_env_value "${ops_main_env}" "DATABASE_URL" "pgsql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};user=${DB_USER};password=${DB_PASSWORD}"
  chmod 600 "${ops_main_env}"

  if ! is_safe_sql_identifier "${DB_OWNER}" || ! is_safe_sql_identifier "${DB_SCHEMA_NAME}" || ! is_safe_sql_identifier "${DB_SCHEMA_OWNER}"; then
    echo "Unsafe DB_OWNER, DB_SCHEMA_NAME or DB_SCHEMA_OWNER." >&2
    exit 1
  fi

  if [[ ! -d "${release_dir}/sql" ]]; then
    echo "No sql directory found in ${release_dir}; skipping DB SQL bootstrap."
    return 0
  fi

  if [[ "${DB_HOST}" == "127.0.0.1" || "${DB_HOST}" == "localhost" ]] && [[ -z "${DB_ADMIN_PASSWORD}" ]]; then
    db_admin_psql_base=(su -s /bin/bash - postgres -c)
  else
    db_admin_psql_base=(env "PGPASSWORD=${DB_ADMIN_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_ADMIN_USER}" -d "${DB_ADMIN_DB}")
  fi

  mapfile -t sql_files < <(find "${release_dir}/sql" -maxdepth 1 -type f -name "*.sql" ! -name "0_*" -printf "%f\n" | sort)
  for sql_file in "${sql_files[@]}"; do
    if [[ "${sql_file}" == 1_* ]]; then
      phase1_sql_files+=("${sql_file}")
    else
      phase2_sql_files+=("${sql_file}")
    fi
  done

  for sql_file in "${phase1_sql_files[@]}"; do
    echo "Running admin sql/${sql_file}"
    if [[ "${db_admin_psql_base[0]}" == "su" ]]; then
      "${db_admin_psql_base[@]}" "psql -d '${DB_ADMIN_DB}' -v ON_ERROR_STOP=1 -v db_name='${DB_NAME}' -v db_user='${DB_USER}' -v db_password='${DB_PASSWORD}' -v db_owner='${DB_OWNER}' -v schema_name='${DB_SCHEMA_NAME}' -v schema_owner='${DB_SCHEMA_OWNER}' -f '${release_dir}/sql/${sql_file}'"
    else
      "${db_admin_psql_base[@]}" \
        -v ON_ERROR_STOP=1 \
        -v db_name="${DB_NAME}" \
        -v db_user="${DB_USER}" \
        -v db_password="${DB_PASSWORD}" \
        -v db_owner="${DB_OWNER}" \
        -v schema_name="${DB_SCHEMA_NAME}" \
        -v schema_owner="${DB_SCHEMA_OWNER}" \
        -f "${release_dir}/sql/${sql_file}"
    fi
  done

  for sql_file in "${phase2_sql_files[@]}"; do
    sql_path="${release_dir}/sql/${sql_file}"
    run_sql_path="${sql_path}"
    temp_sql=""

    if [[ "${sql_file}" == 3_* ]]; then
      temp_sql="$(mktemp)"
      cp "${sql_path}" "${temp_sql}"
      perl -pi -e 'if (/^INSERT INTO / && /;$/ && !/ON CONFLICT DO NOTHING;$/) { s/;$/ ON CONFLICT DO NOTHING;/ }' "${temp_sql}"
      run_sql_path="${temp_sql}"
    fi

    echo "Running app sql/${sql_file}"
    PGPASSWORD="${DB_PASSWORD}" psql \
      -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
      -v ON_ERROR_STOP=1 \
      -v db_name="${DB_NAME}" \
      -v db_user="${DB_USER}" \
      -v db_password="${DB_PASSWORD}" \
      -v db_owner="${DB_OWNER}" \
      -v schema_name="${DB_SCHEMA_NAME}" \
      -v schema_owner="${DB_SCHEMA_OWNER}" \
      -f "${run_sql_path}"

    if [[ -n "${temp_sql}" ]]; then
      rm -f "${temp_sql}"
    fi
  done
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

shared_public_dirs_array() {
  read -r -a dirs <<< "${SHARED_PUBLIC_DIRS}"
  printf '%s\n' "${dirs[@]}"
}

ensure_node_runtime() {
  local node_bin="${NODE_BIN_DIR}/node"
  local npm_bin="${NODE_BIN_DIR}/npm"
  local npx_bin="${NODE_BIN_DIR}/npx"
  local version=""

  if [[ ! -x "${node_bin}" || ! -x "${npm_bin}" || ! -x "${npx_bin}" ]]; then
    echo "Missing required Node runtime in ${NODE_BIN_DIR}." >&2
    echo "Expected node/npm/npx from NVM Node v${REQUIRED_NODE_VERSION}." >&2
    echo "Install it for ${APP_USER}, for example:" >&2
    echo "  su -s /bin/bash - ${APP_USER} -c 'source ~/.nvm/nvm.sh && nvm install v${REQUIRED_NODE_VERSION}'" >&2
    exit 1
  fi

  version="$("${node_bin}" -p 'process.versions.node' 2>/dev/null || true)"
  if [[ "${version}" != "${REQUIRED_NODE_VERSION}" ]]; then
    echo "Node version mismatch in ${NODE_BIN_DIR}: expected ${REQUIRED_NODE_VERSION}, got ${version:-unknown}." >&2
    exit 1
  fi
}

build_spa_pwa() {
  local release_dir="$1"
  su -s /bin/bash - "${APP_USER}" -c "set -Eeuo pipefail; export PATH='${NODE_BIN_DIR}':\$PATH; cd '${release_dir}'; if [[ -f web/package.json ]]; then npm --prefix web ci; cd web; else npm ci; fi; npx quasar build -m pwa"
}

echo "Installing required system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update

PHP_VERSION="$(resolve_php_version "${PHP_VERSION}")"
if [[ -z "${PHP_FPM_SERVICE}" ]]; then
  PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
fi
if [[ -z "${PHP_FPM_SOCK}" ]]; then
  PHP_FPM_SOCK="/run/php/${PHP_FPM_SERVICE}-${APP_NAME}.sock"
fi

echo "Using PHP version ${PHP_VERSION}"
apt-get install -y \
  git curl unzip ca-certificates lsb-release apt-transport-https software-properties-common gnupg2 openssl \
  apache2 libapache2-mod-fcgid postgresql postgresql-client \
  "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" \
  "php${PHP_VERSION}-common" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-dom" \
  "php${PHP_VERSION}-xml" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-gd" \
  "php${PHP_VERSION}-zip" "php${PHP_VERSION}-pgsql"

if systemctl list-unit-files | grep -q '^postgresql\.service'; then
  systemctl enable --now postgresql
fi

if ! require_php_pkg "php${PHP_VERSION}-bcmath"; then
  [[ "${ALLOW_MISSING_EXTENSIONS}" == "1" ]] || exit 1
fi
if ! require_php_pkg "php${PHP_VERSION}-raphf"; then
  [[ "${ALLOW_MISSING_EXTENSIONS}" == "1" ]] || exit 1
fi
if ! require_php_pkg "php${PHP_VERSION}-http"; then
  [[ "${ALLOW_MISSING_EXTENSIONS}" == "1" ]] || exit 1
fi

phpenmod -v "${PHP_VERSION}" bcmath || true
phpenmod -v "${PHP_VERSION}" raphf || true
phpenmod -v "${PHP_VERSION}" http || true

REQUIRED_EXTENSIONS=(curl dom gd iconv libxml pdo simplexml bcmath raphf http)
MISSING_EXTENSIONS=()
for ext in "${REQUIRED_EXTENSIONS[@]}"; do
  if ! extension_is_loaded "${ext}"; then
    MISSING_EXTENSIONS+=("${ext}")
  fi
done
if (( ${#MISSING_EXTENSIONS[@]} > 0 )) && [[ "${ALLOW_MISSING_EXTENSIONS}" != "1" ]]; then
  echo "Missing required PHP extensions for php${PHP_VERSION}: ${MISSING_EXTENSIONS[*]}" >&2
  exit 1
fi

if ! command -v composer >/dev/null 2>&1; then
  EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
  ACTUAL_SIGNATURE="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
  if [[ "${EXPECTED_SIGNATURE}" != "${ACTUAL_SIGNATURE}" ]]; then
    echo "Composer installer signature mismatch." >&2
    exit 1
  fi
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
fi

if [[ "${ENABLE_WEB_BUILD}" == "1" ]]; then
  ensure_node_runtime
fi

echo "Enabling Apache modules..."
a2enmod proxy proxy_fcgi rewrite headers setenvif
a2dismod php7.2 >/dev/null 2>&1 || true
a2dismod php7.4 >/dev/null 2>&1 || true
a2dismod php8.1 >/dev/null 2>&1 || true
a2dismod php8.2 >/dev/null 2>&1 || true

echo "Creating application user and directories..."
id -u "${APP_USER}" >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "${APP_USER}"
mkdir -p "${APP_BASE_DIR}/"{releases,shared,var}
mkdir -p "${APP_BASE_DIR}/shared/var/log" "${APP_BASE_DIR}/shared/var/cache"
while IFS= read -r public_dir; do
  [[ -n "${public_dir}" ]] || continue
  mkdir -p "${APP_BASE_DIR}/shared/public/${public_dir}"
done < <(shared_public_dirs_array)
chown -R "${APP_USER}:${APP_GROUP}" "${APP_BASE_DIR}"

echo "Configuring PHP-FPM pool for ${APP_NAME}..."
POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/${APP_NAME}.conf"
cat > "${POOL_CONF}" <<EOF
[${APP_NAME}]
user = ${APP_USER}
group = ${APP_GROUP}
listen = ${PHP_FPM_SOCK}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
chdir = /
php_admin_value[error_log] = ${APP_BASE_DIR}/shared/var/log/php-fpm.log
php_admin_flag[log_errors] = on
EOF

echo "Configuring Apache vhost..."
VHOST_CONF="/etc/apache2/sites-available/${APP_NAME}.conf"
cat > "${VHOST_CONF}" <<EOF
<VirtualHost *:80>
    ServerName ${APP_DOMAIN}

    DocumentRoot ${APP_BASE_DIR}/current/web/dist/spa

    <Directory ${APP_BASE_DIR}/current/web/dist/spa>
        AllowOverride None
        Require all granted
        FallbackResource /index.html
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${APP_NAME}_spa_error.log
    CustomLog \${APACHE_LOG_DIR}/${APP_NAME}_spa_access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName ${API_DOMAIN}

    DocumentRoot ${APP_BASE_DIR}/current/public

    <Directory ${APP_BASE_DIR}/current/public>
        AllowOverride All
        Require all granted
        FallbackResource /index.php
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:${PHP_FPM_SOCK}|fcgi://localhost/"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${APP_NAME}_api_error.log
    CustomLog \${APACHE_LOG_DIR}/${APP_NAME}_api_access.log combined
</VirtualHost>
EOF
a2ensite "${APP_NAME}.conf"
a2dissite 000-default >/dev/null 2>&1 || true

echo "Validating repository access for ${APP_USER}..."
if ! su -s /bin/bash - "${APP_USER}" -c "export GIT_TERMINAL_PROMPT=0; git ls-remote --exit-code '${APP_REPO_URL}' HEAD >/dev/null 2>&1"; then
  echo "Cannot access APP_REPO_URL as ${APP_USER}: ${APP_REPO_URL}" >&2
  exit 1
fi

echo "Preparing initial release source checkout..."
INIT_RELEASE="${APP_BASE_DIR}/releases/init-$(date +%Y%m%d%H%M%S)"
su -s /bin/bash - "${APP_USER}" -c "export GIT_TERMINAL_PROMPT=0; git clone '${APP_REPO_URL}' '${INIT_RELEASE}'"
su -s /bin/bash - "${APP_USER}" -c "export GIT_TERMINAL_PROMPT=0; cd '${INIT_RELEASE}' && git fetch --tags origin '${GIT_REF}' && git checkout -q FETCH_HEAD"

echo "Checking PHP extensions required by composer files..."
mapfile -t PROJECT_REQUIRED_EXTENSIONS < <(collect_required_project_extensions "${INIT_RELEASE}" | sed '/^$/d')
if (( ${#PROJECT_REQUIRED_EXTENSIONS[@]} > 0 )); then
  mapfile -t UNIQUE_SUFFIXES < <(
    printf '%s\n' "${PROJECT_REQUIRED_EXTENSIONS[@]}" \
      | while read -r ext; do php_pkg_suffix_for_extension "${ext}"; done \
      | sort -u
  )
  for suffix in "${UNIQUE_SUFFIXES[@]}"; do
    if extension_is_loaded "${suffix}"; then
      continue
    fi
    require_php_pkg "php${PHP_VERSION}-${suffix}" || true
    phpenmod -v "${PHP_VERSION}" "${suffix}" >/dev/null 2>&1 || true
  done
fi

echo "Preparing ops env files in ${OPS_ENV_DIR}..."
prepare_ops_env_files "${INIT_RELEASE}"

if [[ "${ENABLE_DB_BOOTSTRAP}" == "1" ]]; then
  bootstrap_database "${INIT_RELEASE}"
fi

echo "Copying env files into release..."
copy_ops_env_to_release "${INIT_RELEASE}"

echo "Installing PHP dependencies..."
su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && APP_ENV='${APP_RUNTIME_ENV}' APP_DEBUG=0 composer install --no-dev --optimize-autoloader --classmap-authoritative"

if [[ "${ENABLE_WEB_BUILD}" == "1" ]]; then
  echo "Installing and building SPA in PWA mode with Node v${REQUIRED_NODE_VERSION}..."
  build_spa_pwa "${INIT_RELEASE}"
fi

echo "Clearing Symfony cache..."
su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && APP_ENV='${APP_RUNTIME_ENV}' APP_DEBUG=0 php${PHP_VERSION} bin/console cache:clear --env=${APP_RUNTIME_ENV} --no-debug"

ln -sfn "${INIT_RELEASE}" "${APP_BASE_DIR}/current"
chown -h "${APP_USER}:${APP_GROUP}" "${APP_BASE_DIR}/current"

echo "Validating services and reloading..."
apache2ctl configtest
systemctl restart "${PHP_FPM_SERVICE}"
systemctl reload "${APACHE_SERVICE}"

echo
echo "Initialization complete."
echo "App directory: ${APP_BASE_DIR}"
echo "Current release: ${INIT_RELEASE}"
echo "Ops env dir: ${OPS_ENV_DIR}"
echo "Vhost: ${VHOST_CONF}"
echo "FPM pool: ${POOL_CONF}"
