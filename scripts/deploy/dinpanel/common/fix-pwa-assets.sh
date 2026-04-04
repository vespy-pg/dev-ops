#!/usr/bin/env bash
set -Eeuo pipefail

APP_BASE_DIR="${APP_BASE_DIR:-/var/www/dinpanel}"
WEB_DIST_DIR="${WEB_DIST_DIR:-pwa}"
APP_DOMAIN="${APP_DOMAIN:-dinpanel.com}"

CURRENT_RELEASE="$(readlink -f "${APP_BASE_DIR}/current" 2>/dev/null || true)"
if [[ -z "${CURRENT_RELEASE}" || ! -d "${CURRENT_RELEASE}" ]]; then
  echo "Cannot resolve current release from ${APP_BASE_DIR}/current" >&2
  exit 1
fi

DIST_ROOT="${CURRENT_RELEASE}/web/dist/${WEB_DIST_DIR}"
ICONS_DIR="${DIST_ROOT}/icons"
if [[ ! -d "${DIST_ROOT}" ]]; then
  echo "Missing dist root: ${DIST_ROOT}" >&2
  exit 1
fi

mkdir -p "${ICONS_DIR}"

copy_icon_if_missing() {
  local icon_name="$1"
  local source=""
  if [[ -f "${ICONS_DIR}/${icon_name}" ]]; then
    return 0
  fi
  for source in \
    "${DIST_ROOT}/img/icons/${icon_name}" \
    "${CURRENT_RELEASE}/web/src-pwa/icons/${icon_name}" \
    "${CURRENT_RELEASE}/web/public/icons/${icon_name}"; do
    if [[ -f "${source}" ]]; then
      install -m 644 "${source}" "${ICONS_DIR}/${icon_name}"
      return 0
    fi
  done
  return 1
}

for icon_name in \
  icon-128x128.png \
  icon-192x192.png \
  icon-256x256.png \
  icon-384x384.png \
  icon-512x512.png \
  icon-512x512-maskable.png; do
  copy_icon_if_missing "${icon_name}" || true
done

MISSING=()
for required in \
  manifest.json \
  sw.js \
  icons/icon-128x128.png \
  icons/icon-192x192.png \
  icons/icon-256x256.png \
  icons/icon-384x384.png \
  icons/icon-512x512.png \
  icons/icon-512x512-maskable.png; do
  if [[ ! -f "${DIST_ROOT}/${required}" ]]; then
    MISSING+=("${required}")
  fi
done

if (( ${#MISSING[@]} > 0 )); then
  echo "Still missing required files in ${DIST_ROOT}: ${MISSING[*]}" >&2
  exit 1
fi

echo "PWA assets are present in ${DIST_ROOT}."
echo "Quick checks:"
curl -I "https://${APP_DOMAIN}/icons/icon-192x192.png"
curl -I "https://${APP_DOMAIN}/icons/icon-512x512.png"
curl -I "https://${APP_DOMAIN}/manifest.json"
curl -I "https://${APP_DOMAIN}/sw.js"
