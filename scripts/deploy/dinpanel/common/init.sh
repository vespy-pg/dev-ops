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
DB_USER="${DB_USER:-dinpanel_user}"
DB_ADMIN_DB="${DB_ADMIN_DB:-postgres}"
DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-}"

ENABLE_DB_BOOTSTRAP="${ENABLE_DB_BOOTSTRAP:-1}" # 1 = create db/user and run sql/[!0_]*
ENABLE_WEB_BUILD="${ENABLE_WEB_BUILD:-0}"       # 1 = install node/npm and build web
ALLOW_MISSING_EXTENSIONS="${ALLOW_MISSING_EXTENSIONS:-0}" # 1 = pre-prod fallback
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"         # 1 = no prompts

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

  mkdir -p "${OPS_ENV_DIR}"
  touch "${gitignore_file}"
  if ! grep -qxF "*.env" "${gitignore_file}"; then
    echo "*.env" >> "${gitignore_file}"
  fi

  mapfile -t EXAMPLE_FILES < <(find "${release_env_dir}" -maxdepth 1 -type f -name "*.env.example" -printf "%f\n" | sort)

  if (( ${#EXAMPLE_FILES[@]} == 0 )); then
    echo "No *.env.example files found in ${release_env_dir}" >&2
    exit 1
  fi

  for example_name in "${EXAMPLE_FILES[@]}"; do
    target_name="${example_name%.example}"
    source_file="${release_env_dir}/${example_name}"
    target_file="${OPS_ENV_DIR}/${target_name}"

    if [[ -f "${target_file}" ]] && ! prompt_overwrite_default_no "${target_file}"; then
      echo "Keeping existing ${target_file}"
    else
      cp "${source_file}" "${target_file}"
      echo "Prepared ${target_file}"
    fi
    chmod 600 "${target_file}"
  done
}

bootstrap_database() {
  local release_dir="$1"
  local ops_main_env="${OPS_ENV_DIR}/.env"
  local db_password_sql=""
  local db_name_sql=""
  local db_user_sql=""
  local sql_file=""
  local -a sql_files=()

  if [[ ! -f "${ops_main_env}" ]]; then
    echo "Missing ${ops_main_env}. Cannot bootstrap database." >&2
    exit 1
  fi

  DB_NAME="$(normalize_name_with_env_suffix "${DB_NAME}")"
  DB_USER="$(normalize_name_with_env_suffix "${DB_USER}")"
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
  set_env_value "${ops_main_env}" "DB_PASSWORD" "${DB_PASSWORD}"
  set_env_value "${ops_main_env}" "DATABASE_URL" "pgsql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};user=${DB_USER};password=${DB_PASSWORD}"
  chmod 600 "${ops_main_env}"

  db_password_sql="${DB_PASSWORD//\'/\'\'}"
  db_name_sql="${DB_NAME//\'/\'\'}"
  db_user_sql="${DB_USER//\'/\'\'}"

  echo "Creating/updating PostgreSQL role and database..."
  PGPASSWORD="${DB_ADMIN_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_ADMIN_USER}" -d "${DB_ADMIN_DB}" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${db_user_sql}') THEN
    EXECUTE 'ALTER ROLE "${DB_USER}" LOGIN PASSWORD ''${db_password_sql}''';
  ELSE
    EXECUTE 'CREATE ROLE "${DB_USER}" LOGIN PASSWORD ''${db_password_sql}''';
  END IF;
END
\$\$;
SQL

  if ! PGPASSWORD="${DB_ADMIN_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_ADMIN_USER}" -d "${DB_ADMIN_DB}" -Atqc "SELECT 1 FROM pg_database WHERE datname='${db_name_sql}'" | grep -q '^1$'; then
    PGPASSWORD="${DB_ADMIN_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_ADMIN_USER}" -d "${DB_ADMIN_DB}" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\""
  fi
  PGPASSWORD="${DB_ADMIN_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_ADMIN_USER}" -d "${DB_ADMIN_DB}" -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\""

  mapfile -t sql_files < <(find "${release_dir}/sql" -maxdepth 1 -type f -name "*.sql" ! -name "0_*" -printf "%f\n" | sort)
  for sql_file in "${sql_files[@]}"; do
    echo "Running sql/${sql_file}"
    PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -f "${release_dir}/sql/${sql_file}"
  done
}

copy_ops_env_to_release() {
  local release_dir="$1"
  local release_env_dir="${release_dir}/env"
  local ops_env_file=""

  mkdir -p "${release_env_dir}"
  while IFS= read -r -d '' ops_env_file; do
    cp "${ops_env_file}" "${release_env_dir}/$(basename "${ops_env_file}")"
  done < <(find "${OPS_ENV_DIR}" -maxdepth 1 -type f -name "*.env" -print0 | sort -z)
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
  apache2 libapache2-mod-fcgid postgresql-client \
  "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" \
  "php${PHP_VERSION}-common" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-dom" \
  "php${PHP_VERSION}-xml" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-gd" \
  "php${PHP_VERSION}-zip" "php${PHP_VERSION}-pgsql"

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

if [[ "${ENABLE_WEB_BUILD}" == "1" ]] && ! command -v npm >/dev/null 2>&1; then
  apt-get install -y nodejs npm
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
mkdir -p "${APP_BASE_DIR}/shared"/{var/log,var/cache,public/uploads}
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

    DocumentRoot ${APP_BASE_DIR}/current/public

    <Directory ${APP_BASE_DIR}/current/public>
        AllowOverride All
        Require all granted
        FallbackResource /index.php
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:${PHP_FPM_SOCK}|fcgi://localhost/"
    </FilesMatch>

    ErrorLog \${APACHE_LOG_DIR}/${APP_NAME}_error.log
    CustomLog \${APACHE_LOG_DIR}/${APP_NAME}_access.log combined
</VirtualHost>
EOF
a2ensite "${APP_NAME}.conf"

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
su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && composer install --no-dev --optimize-autoloader --classmap-authoritative"

if [[ "${ENABLE_WEB_BUILD}" == "1" ]]; then
  echo "Installing and building SPA..."
  su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && npm ci && npm run web:build"
fi

echo "Clearing Symfony cache..."
su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && php${PHP_VERSION} bin/console cache:clear --env=${APP_RUNTIME_ENV} --no-debug"

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
