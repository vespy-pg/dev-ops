#!/usr/bin/env bash
set -Eeuo pipefail

# Hotfix for existing production instance:
# 1) ensure ACME challenge path is reachable
# 2) re-issue/expand cert with dinpanel.com + www + api
# 3) reload Apache
#
# Usage:
#   sudo ./fix-existing-prod-tls.sh <email>
#
# Example:
#   sudo ./fix-existing-prod-tls.sh admin@dinpanel.com

EMAIL="${1:-}"
if [[ -z "${EMAIL}" ]]; then
  echo "Usage: sudo $0 <email>" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

CERT_NAME="dinpanel.com"
TLS_DOMAINS=(dinpanel.com www.dinpanel.com api.dinpanel.com)
ACME_ROOT="/var/www/letsencrypt"
ACME_DIR="${ACME_ROOT}/.well-known/acme-challenge"
APACHE_SITE="/etc/apache2/sites-available/dinpanel.conf"
APACHE_ACME_CONF="/etc/apache2/conf-available/letsencrypt-acme-challenge.conf"
BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"

if [[ ! -f "${APACHE_SITE}" ]]; then
  echo "Expected Apache vhost not found: ${APACHE_SITE}" >&2
  exit 1
fi

mkdir -p "${ACME_DIR}"
chown -R www-data:www-data "${ACME_ROOT}"
chmod 755 "${ACME_ROOT}" "${ACME_ROOT}/.well-known" "${ACME_DIR}"

cat > "${APACHE_ACME_CONF}" <<'EOF'
Alias /.well-known/acme-challenge/ /var/www/letsencrypt/.well-known/acme-challenge/
<Directory /var/www/letsencrypt/.well-known/acme-challenge/>
    Options None
    AllowOverride None
    ForceType text/plain
    Require all granted
</Directory>
EOF

a2enconf letsencrypt-acme-challenge >/dev/null

cp -a "${APACHE_SITE}" "${APACHE_SITE}.bak.${BACKUP_SUFFIX}"
if ! grep -q 'REQUEST_URI} !^/\\.well-known/acme-challenge/' "${APACHE_SITE}"; then
  sed -i '/RewriteEngine On/a\    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/ [NC]' "${APACHE_SITE}"
fi

apache2ctl configtest
systemctl reload apache2

PROBE_NAME="acme-probe-${BACKUP_SUFFIX}"
PROBE_PATH="${ACME_DIR}/${PROBE_NAME}"
echo "ok-${PROBE_NAME}" > "${PROBE_PATH}"

for host in "${TLS_DOMAINS[@]}"; do
  echo "Checking challenge path on ${host}..."
  body="$(curl -fsS "http://${host}/.well-known/acme-challenge/${PROBE_NAME}" || true)"
  if [[ "${body}" != "ok-${PROBE_NAME}" ]]; then
    echo "ACME probe failed on ${host}. Got: ${body}" >&2
    echo "Backup vhost: ${APACHE_SITE}.bak.${BACKUP_SUFFIX}" >&2
    rm -f "${PROBE_PATH}"
    exit 1
  fi
done

rm -f "${PROBE_PATH}"

if ! command -v certbot >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y certbot
fi

certbot certonly --webroot -w "${ACME_ROOT}" \
  --cert-name "${CERT_NAME}" \
  -d "${TLS_DOMAINS[0]}" -d "${TLS_DOMAINS[1]}" -d "${TLS_DOMAINS[2]}" \
  --agree-tos --email "${EMAIL}" --non-interactive --expand

apache2ctl configtest
systemctl reload apache2

echo
echo "Certificate details:"
certbot certificates --cert-name "${CERT_NAME}"
echo
echo "Done."

