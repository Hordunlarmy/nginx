#!/bin/sh
echo "[CRON] Checking cert renewal..."
certbot renew --webroot -w /var/www/certbot --post-hook "nginx -s reload"
