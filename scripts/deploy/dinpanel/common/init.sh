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

APP_NAME="${APP_NAME:-dinpanel}"
if [[ "${DEPLOY_ENV_NORMALIZED}" == "prod" ]]; then
  APP_DOMAIN="dinpanel.com"
else
  APP_DOMAIN="${DEPLOY_ENV_NORMALIZED}.dinpanel.com"
fi
APP_USER="${APP_USER:-pawel}"
APP_GROUP="${APP_GROUP:-www-data}"
APP_BASE_DIR="${APP_BASE_DIR:-/var/www/${APP_NAME}}"
APP_REPO_URL="${APP_REPO_URL:-https://github.com/vespy-pg/DINPanel.git}"
GIT_REF="${GIT_REF:-main}"
APP_RUNTIME_ENV="${APP_RUNTIME_ENV:-prod}"

PHP_VERSION="${PHP_VERSION:-auto}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"
PHP_FPM_SOCK="${PHP_FPM_SOCK:-}"
APACHE_SERVICE="${APACHE_SERVICE:-apache2}"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-dinpanel}"
DB_USER="${DB_USER:-dinpanel_user}"
DB_PASSWORD="${DB_PASSWORD:-change_me}"
DB_ADMIN_DB="${DB_ADMIN_DB:-postgres}"
DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-}"
DB_SERVER_VERSION="${DB_SERVER_VERSION:-16}"

ENABLE_DB_BOOTSTRAP="${ENABLE_DB_BOOTSTRAP:-0}" # 1 = run sql/1,2,3
ENABLE_WEB_BUILD="${ENABLE_WEB_BUILD:-0}"       # 1 = install node/npm and build web
OVERWRITE_ENV_FILE="${OVERWRITE_ENV_FILE:-0}"   # 1 = replace existing .env.local
ALLOW_MISSING_EXTENSIONS="${ALLOW_MISSING_EXTENSIONS:-0}" # 1 = pre-prod fallback

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

echo "Installing required system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update

resolve_php_version() {
  local requested="$1"
  local candidates=(8.4 8.3 8.2 8.1 8.0)
  local detected=""

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

PHP_VERSION="$(resolve_php_version "${PHP_VERSION}")"
if [[ -z "${PHP_FPM_SERVICE}" ]]; then
  PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
fi
if [[ -z "${PHP_FPM_SOCK}" ]]; then
  PHP_FPM_SOCK="/run/php/${PHP_FPM_SERVICE}-${APP_NAME}.sock"
fi

echo "Using PHP version ${PHP_VERSION}"

apt-get install -y \
  git curl unzip ca-certificates lsb-release apt-transport-https software-properties-common gnupg2 \
  apache2 libapache2-mod-fcgid \
  "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" \
  "php${PHP_VERSION}-common" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-dom" \
  "php${PHP_VERSION}-xml" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-intl" \
  "php${PHP_VERSION}-zip" "php${PHP_VERSION}-pgsql"

require_php_pkg() {
  local pkg="$1"
  if ! apt-cache show "${pkg}" >/dev/null 2>&1; then
    echo "Required package not found: ${pkg}" >&2
    echo "This usually means your apt PHP repository does not provide PHP ${PHP_VERSION} extensions." >&2
    echo "Ensure ppa:ondrej/php is enabled and apt metadata is refreshed." >&2
    echo "Suggested commands:" >&2
    echo "  sudo add-apt-repository -y ppa:ondrej/php" >&2
    echo "  sudo apt-get update" >&2
    return 1
  fi
  apt-get install -y "${pkg}"
}

if ! require_php_pkg "php${PHP_VERSION}-bcmath"; then
  if [[ "${ALLOW_MISSING_EXTENSIONS}" != "1" ]]; then
    echo "Unable to install bcmath extension package for PHP ${PHP_VERSION}." >&2
    exit 1
  fi
  echo "Warning: bcmath package unavailable for PHP ${PHP_VERSION}; continuing because ALLOW_MISSING_EXTENSIONS=1"
fi

if ! require_php_pkg "php${PHP_VERSION}-raphf"; then
  if [[ "${ALLOW_MISSING_EXTENSIONS}" != "1" ]]; then
    echo "Unable to install raphf extension package for PHP ${PHP_VERSION}." >&2
    exit 1
  fi
  echo "Warning: raphf package unavailable for PHP ${PHP_VERSION}; continuing because ALLOW_MISSING_EXTENSIONS=1"
fi

if ! require_php_pkg "php${PHP_VERSION}-http"; then
  if [[ "${ALLOW_MISSING_EXTENSIONS}" != "1" ]]; then
    echo "Unable to install http extension package for PHP ${PHP_VERSION}." >&2
    exit 1
  fi
  echo "Warning: http package unavailable for PHP ${PHP_VERSION}; continuing because ALLOW_MISSING_EXTENSIONS=1"
fi

phpenmod -v "${PHP_VERSION}" bcmath || true
phpenmod -v "${PHP_VERSION}" raphf || true
phpenmod -v "${PHP_VERSION}" http || true

REQUIRED_EXTENSIONS=(curl dom iconv libxml pdo simplexml bcmath raphf http)
MISSING_EXTENSIONS=()
for ext in "${REQUIRED_EXTENSIONS[@]}"; do
  if ! "php${PHP_VERSION}" -m | awk '{print tolower($0)}' | grep -q "^${ext}$"; then
    MISSING_EXTENSIONS+=("${ext}")
  fi
done

if (( ${#MISSING_EXTENSIONS[@]} > 0 )); then
  if [[ "${ALLOW_MISSING_EXTENSIONS}" != "1" ]]; then
    echo "Missing required PHP extensions for php${PHP_VERSION}: ${MISSING_EXTENSIONS[*]}" >&2
    echo "Install them and re-run. Composer will fail without required extensions." >&2
    exit 1
  fi
  echo "Warning: missing PHP extensions for php${PHP_VERSION}: ${MISSING_EXTENSIONS[*]}"
  echo "Warning: continuing because ALLOW_MISSING_EXTENSIONS=1 (temporary pre-prod mode)."
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
mkdir -p "${APP_BASE_DIR}/shared"/{env,var/log,var/cache,public/uploads}
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
  echo "For private repositories, configure non-interactive auth and re-run." >&2
  echo "Recommended: APP_REPO_URL=git@github.com:<org>/<repo>.git with SSH key for ${APP_USER}." >&2
  echo "Alternative: APP_REPO_URL=https://<user>:<token>@github.com/<org>/<repo>.git" >&2
  exit 1
fi

echo "Preparing initial release source checkout..."
INIT_RELEASE="${APP_BASE_DIR}/releases/init-$(date +%Y%m%d%H%M%S)"
su -s /bin/bash - "${APP_USER}" -c "export GIT_TERMINAL_PROMPT=0; git clone '${APP_REPO_URL}' '${INIT_RELEASE}'"
su -s /bin/bash - "${APP_USER}" -c "export GIT_TERMINAL_PROMPT=0; cd '${INIT_RELEASE}' && git fetch --tags origin '${GIT_REF}' && git checkout -q FETCH_HEAD"
ln -sfn "${APP_BASE_DIR}/shared/env/.env.local" "${INIT_RELEASE}/env/.env.local"

if [[ ! -f "${APP_BASE_DIR}/shared/env/.env.local" ]]; then
  if [[ -f "${INIT_RELEASE}/env/.env.example" ]]; then
    cp "${INIT_RELEASE}/env/.env.example" "${APP_BASE_DIR}/shared/env/.env.local"
  else
    touch "${APP_BASE_DIR}/shared/env/.env.local"
  fi
fi

if [[ ! -f "${APP_BASE_DIR}/shared/env/.env.local" || "${OVERWRITE_ENV_FILE}" == "1" ]]; then
cat > "${APP_BASE_DIR}/shared/env/.env.local" <<EOF
APP_ENV=${APP_RUNTIME_ENV}
APP_DEBUG=0
APP_SECRET=CHANGE_ME_TO_LONG_RANDOM_VALUE
DATABASE_URL=pgsql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_NAME};user=${DB_USER};password=${DB_PASSWORD}
EOF
fi
chown "${APP_USER}:${APP_GROUP}" "${APP_BASE_DIR}/shared/env/.env.local"
chmod 0640 "${APP_BASE_DIR}/shared/env/.env.local"

echo "Installing PHP dependencies..."
COMPOSER_INSTALL_FLAGS="--no-dev --optimize-autoloader --classmap-authoritative"
if [[ "${ALLOW_MISSING_EXTENSIONS}" == "1" ]] && (( ${#MISSING_EXTENSIONS[@]} > 0 )); then
  for ext in "${MISSING_EXTENSIONS[@]}"; do
    COMPOSER_INSTALL_FLAGS+=" --ignore-platform-req=ext-${ext}"
  done
fi
su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && composer install ${COMPOSER_INSTALL_FLAGS}"

if [[ "${ENABLE_WEB_BUILD}" == "1" ]]; then
  echo "Installing and building SPA..."
  su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && npm ci && npm run web:build"
fi

echo "Clearing Symfony cache..."
su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && php${PHP_VERSION} bin/console cache:clear --env=${APP_RUNTIME_ENV} --no-debug"

if [[ "${ENABLE_DB_BOOTSTRAP}" == "1" ]]; then
  echo "Running DB bootstrap scripts (1, 2, 3)..."
  su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && PGPASSWORD='${DB_ADMIN_PASSWORD}' psql -h '${DB_HOST}' -p '${DB_PORT}' -U '${DB_ADMIN_USER}' -d '${DB_ADMIN_DB}' -f sql/1_setup_database.sql"
  su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && PGPASSWORD='${DB_PASSWORD}' psql -h '${DB_HOST}' -p '${DB_PORT}' -U '${DB_USER}' -d '${DB_NAME}' -f sql/2_setup_basic_tables.sql"
  su -s /bin/bash - "${APP_USER}" -c "cd '${INIT_RELEASE}' && PGPASSWORD='${DB_PASSWORD}' psql -h '${DB_HOST}' -p '${DB_PORT}' -U '${DB_USER}' -d '${DB_NAME}' -f sql/3_setup_data.sql"
fi

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
echo "Vhost: ${VHOST_CONF}"
echo "FPM pool: ${POOL_CONF}"
echo "Do not run sql/0_setup_cleanup.sql on this server."
