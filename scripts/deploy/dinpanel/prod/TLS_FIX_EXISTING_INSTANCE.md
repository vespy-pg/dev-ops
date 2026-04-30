# TLS Fix For Existing Production Instance

Do **not** run `init.sh` on a working production server.

## Fast path (single script)

Run from this repo on the server:

```bash
sudo /var/www/workspace/vespy-dev-ops/scripts/deploy/dinpanel/prod/fix-existing-prod-tls.sh admin@dinpanel.com
```

## Option A: Immediate fix on existing instance (no app release)

Run on the production server as root:

```bash
sudo mkdir -p /var/www/letsencrypt/.well-known/acme-challenge
sudo certbot certonly --webroot -w /var/www/letsencrypt \
  --cert-name dinpanel.com \
  -d dinpanel.com -d www.dinpanel.com -d api.dinpanel.com \
  --agree-tos --email you@example.com --non-interactive --expand
sudo apache2ctl configtest
sudo systemctl reload apache2
```

Expected after this:
- cert `dinpanel.com` includes SANs: `dinpanel.com`, `www.dinpanel.com`, `api.dinpanel.com`
- Apache must serve `*:443` and redirect `https://www.dinpanel.com/* -> https://dinpanel.com/*` (301)

## Option B: Safe normal deploy path (recommended)

This applies code release + automated TLS config from ops scripts:

```bash
sudo TLS_EMAIL=you@example.com ENABLE_TLS_AUTOMATION=1 \
  /var/www/workspace/vespy-dev-ops/scripts/deploy/dinpanel/prod/deploy.sh
```

## Quick verification

```bash
curl -I https://www.dinpanel.com/
curl -I https://dinpanel.com/
curl -I http://dinpanel.com/
openssl s_client -connect dinpanel.com:443 -servername dinpanel.com </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName
```
