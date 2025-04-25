#!/bin/sh

set -e

log_info() {
  echo "[INFO] $1" >&2  # Redirect to stderr, so it doesn't get mixed into the config
}

log_error() {
  echo "[ERROR] $1" >&2  # Redirect to stderr, so it doesn't get mixed into the config
  exit 1
}

log_info "Starting entrypoint..."

[ -z "$DOMAIN_NAMES" ] && log_error "DOMAIN_NAMES is not set!"
[ -z "$SSL_PROVIDER" ] && log_error "SSL_PROVIDER is not set!"
[ -z "$EMAIL" ] && log_error "EMAIL is not set!"
[ -z "$SECURE" ] && log_error "SECURE is not set!"

PRIMARY_DOMAIN=$(echo "$DOMAIN_NAMES" | cut -d',' -f1)

# Function to generate NGINX location blocks from BLOCKS
generate_location_blocks() {
  has_root_location=false

  log_info "Generating NGINX location blocks..."

  # Iterate through BLOCKS and create the location blocks
  echo "$BLOCKS" | jq -c '.[]' | while read -r block; do
    location=$(echo "$block" | jq -r '.location')
    address=$(echo "$block" | jq -r '.address')

    # Check if it's the root location
    if [ "$location" = "/" ]; then
      has_root_location=true
    fi

    # Default address to localhost if it's missing
    if [[ "$location" != "/" && -z "$address" ]]; then
      location="/"
      address="http://localhost"
    fi

    # Ensure location ends with a trailing slash if it isn't the root
    if [[ "$location" != "/" && "$location" != */ ]]; then
      location="${location}/"
    fi

    # Output the location block
    cat <<EOF
    location "$location" {
        proxy_pass "$address";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
  done
}

# Generate the HTTP blocks
log_info "Generating HTTP blocks..."
HTTP_BLOCKS=$(generate_location_blocks)
log_info "HTTP BLOCKS: $HTTP_BLOCKS"
log_info "Generated HTTP blocks successfully."

HTTPS_BLOCK=""

if [ "$SECURE" = "true" ]; then
  log_info "SECURE is true. Setting up HTTPS block..."

  if [ "$SSL_PROVIDER" = "certbot" ]; then
    log_info "Using certbot to generate certificate..."

    mkdir -p /var/www/certbot

    if ! certbot certonly --webroot -w /var/www/certbot \
      --email "$EMAIL" --agree-tos --no-eff-email \
      -d $DOMAIN_NAMES; then
      log_error "Certbot certificate generation failed!"
    fi

    echo "0 0 * * * certbot renew --post-hook \"nginx -s reload\"" > /etc/crontabs/root

  elif [ "$SSL_PROVIDER" = "selfsigned" ]; then
    log_info "Using self-signed certificate..."
    mkdir -p /etc/letsencrypt/live/${PRIMARY_DOMAIN}

    if ! openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem \
      -out /etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem \
      -subj "/CN=${PRIMARY_DOMAIN}"; then
      log_error "Self-signed certificate creation failed!"
    fi
  else
    log_error "Unknown SSL provider: $SSL_PROVIDER"
  fi

  HTTPS_BLOCK="server {
    listen 443 ssl;
    server_name ${DOMAIN_NAMES};

    ssl_certificate /etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

$(generate_location_blocks)
  }"
fi

log_info "Rendering final nginx.conf..."

# Use envsubst to substitute variables in nginx.conf.template
if ! envsubst '\$DOMAIN_NAMES \$SECURE \$SSL_PROVIDER \$EMAIL \$PRIMARY_DOMAIN' < /etc/nginx/nginx.conf.template > /tmp/nginx.conf.tmp; then
  log_error "Failed to render nginx.conf with HTTP blocks!"
fi

# Insert the generated HTTP blocks into the placeholder in the temporary file
if ! echo "$HTTP_BLOCKS" | sed "/###BLOCKS###/r /dev/stdin" /tmp/nginx.conf.tmp > /tmp/nginx.conf.tmp2; then
  log_error "Failed to insert HTTP blocks into nginx.conf!"
fi

# Insert the HTTPS block into the nginx.conf, if applicable
if [ -n "$HTTPS_BLOCK" ]; then
  if ! sed "s|###HTTPS SERVER###|$HTTPS_BLOCK|" /tmp/nginx.conf.tmp2 > /etc/nginx/nginx.conf; then
    log_error "Failed to insert HTTPS block into nginx.conf!"
  fi
else
  # If no HTTPS block, just use the modified HTTP block
  if ! mv /tmp/nginx.conf.tmp2 /etc/nginx/nginx.conf; then
    log_error "Failed to move temporary nginx.conf to final location!"
  fi
fi

log_info "NGINX configuration generated successfully."

log_info "Starting NGINX..."
exec nginx -g "daemon off;"

