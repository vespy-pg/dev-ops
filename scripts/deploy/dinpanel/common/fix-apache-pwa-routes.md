# Fix Apache PWA Routes on Production (`dinpanel.com`)

Run on the production web server as a sudo-capable user.

```bash
sudo tee /etc/apache2/conf-available/dinpanel-spa-static.conf >/dev/null <<'EOF'
Alias /icons /var/www/dinpanel/current/web/dist/pwa/icons
Alias /manifest.json /var/www/dinpanel/current/web/dist/pwa/manifest.json
Alias /sw.js /var/www/dinpanel/current/web/dist/pwa/sw.js

<Directory /var/www/dinpanel/current/web/dist/pwa/icons>
    AllowOverride None
    Require all granted
</Directory>
EOF

sudo a2enconf dinpanel-spa-static
sudo apache2ctl configtest
sudo systemctl reload apache2
```

Verify:

```bash
curl -I https://dinpanel.com/icons/icon-192x192.png
curl -I https://dinpanel.com/icons/icon-512x512.png
curl -I https://dinpanel.com/manifest.json
curl -I https://dinpanel.com/sw.js
```

Expected: all return `HTTP/1.1 200 OK`.

If icons still return `404`, capture Apache vhost map:

```bash
sudo apachectl -S
```
