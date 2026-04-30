#!/usr/bin/env bash
set -Eeuo pipefail

# Ensure https://www.dinpanel.com/* returns 301 to https://dinpanel.com/*
# Usage:
#   sudo ./fix-www-https-redirect.sh

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

VHOST_FILE="/etc/apache2/sites-available/dinpanel.conf"
TLS_CERT="/etc/letsencrypt/live/dinpanel.com/fullchain.pem"
TLS_KEY="/etc/letsencrypt/live/dinpanel.com/privkey.pem"
STAMP="$(date +%Y%m%d%H%M%S)"

if [[ ! -f "${VHOST_FILE}" ]]; then
  echo "Missing vhost file: ${VHOST_FILE}" >&2
  exit 1
fi

if [[ ! -s "${TLS_CERT}" || ! -s "${TLS_KEY}" ]]; then
  echo "Missing TLS cert/key: ${TLS_CERT} or ${TLS_KEY}" >&2
  exit 1
fi

cp -a "${VHOST_FILE}" "${VHOST_FILE}.bak.${STAMP}"

perl -0777 -i -pe '
  s@<VirtualHost \*:443>\s*ServerName www\.dinpanel\.com\b.*?</VirtualHost>@<VirtualHost *:443>\n    ServerName www.dinpanel.com\n    SSLEngine on\n    SSLCertificateFile /etc/letsencrypt/live/dinpanel.com/fullchain.pem\n    SSLCertificateKeyFile /etc/letsencrypt/live/dinpanel.com/privkey.pem\n\n    RewriteEngine On\n    RewriteRule ^ https://dinpanel.com%{REQUEST_URI} [R=301,L,NE]\n\n    ErrorLog \${APACHE_LOG_DIR}/dinpanel_spa_www_ssl_error.log\n    CustomLog \${APACHE_LOG_DIR}/dinpanel_spa_www_ssl_access.log combined\n</VirtualHost>@s;
' "${VHOST_FILE}"

if ! grep -qE '^\s*ServerName\s+www\.dinpanel\.com\b' "${VHOST_FILE}"; then
  cat >> "${VHOST_FILE}" <<'EOF'

<VirtualHost *:443>
    ServerName www.dinpanel.com
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/dinpanel.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/dinpanel.com/privkey.pem

    RewriteEngine On
    RewriteRule ^ https://dinpanel.com%{REQUEST_URI} [R=301,L,NE]

    ErrorLog ${APACHE_LOG_DIR}/dinpanel_spa_www_ssl_error.log
    CustomLog ${APACHE_LOG_DIR}/dinpanel_spa_www_ssl_access.log combined
</VirtualHost>
EOF
fi

apache2ctl configtest
systemctl reload apache2

echo "Verification:"
curl -sSI https://www.dinpanel.com/ | sed -n '1p;/^Location:/Ip'
echo
echo "Backup: ${VHOST_FILE}.bak.${STAMP}"

