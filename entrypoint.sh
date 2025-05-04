#!/bin/bash

set -e

log_info() {
  echo "[INFO] $1" >&2
}

log_error() {
  echo "[ERROR] $1" >&2
}

log_info "Starting entrypoint..."

CONFIG_JSON="/etc/nginx/config.json"

if [ ! -f "$CONFIG_JSON" ]; then
  log_error "Config file $CONFIG_JSON not found!"
  exit 1
fi

DOMAIN_NAMES=$(jq -r '.DOMAIN_NAMES' "$CONFIG_JSON")
SECURE=$(jq -r '.SECURE' "$CONFIG_JSON")
SSL_PROVIDER=$(jq -r '.SSL_PROVIDER' "$CONFIG_JSON")
EMAIL=$(jq -r '.EMAIL' "$CONFIG_JSON")
ENABLE_HTTP_REDIRECT=$(jq -r '.ENABLE_HTTP_REDIRECT' "$CONFIG_JSON")
BLOCKS=$(jq -c '.BLOCKS' "$CONFIG_JSON")

IFS=',' read -ra DOMAINS <<< "$DOMAIN_NAMES"

[ -z "$DOMAIN_NAMES" ] && log_error "DOMAIN_NAMES is not set!"
[ -z "$SSL_PROVIDER" ] && log_error "SSL_PROVIDER is not set!"
[ -z "$EMAIL" ] && log_error "EMAIL is not set!"
[ -z "$SECURE" ] && log_error "SECURE is not set!"

generate_location_blocks_for_domain() {
  local domain="$1"
  local output=""

  while IFS= read -r block; do
    domains=$(echo "$block" | jq -r '.domains[]? // empty' | tr '\n' ' ')
    if [ -n "$domains" ]; then
      found=false
      for d in $domains; do
        if [ "$d" == "$domain" ]; then
          found=true
          break
        fi
      done
      [ "$found" != true ] && continue
    fi

    location=$(echo "$block" | jq -r '.location')
    address=$(echo "$block" | jq -r '.address // empty')
    type=$(echo "$block" | jq -r '.type // "http"')
    root=$(echo "$block" | jq -r '.root // empty')
    additional_directives=$(echo "$block" | jq -c '.additional_directives // []')

    address="${address#http://}"
    address="${address#https://}"

    if [[ "$location" != "/" && "$location" != */ && "$location" != "~ "* ]]; then
      location="${location}/"
    fi

    output="${output}
location $location {"

    [ -n "$root" ] && output="${output}
        root $root;"

    if [[ "$type" == "custom" ]]; then
      :
    elif [[ "$type" == "websocket" ]]; then
      output="${output}
        proxy_http_version 1.1;
        proxy_pass http://$address;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection upgrade;
        proxy_buffering off;"
    elif [[ "$type" == "php" ]]; then
      output="${output}
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\\.php)(/.+)\$;
        fastcgi_pass $address;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;"
    else
      output="${output}
        proxy_pass http://$address;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;"
    fi

    while IFS= read -r directive; do
      [ -n "$directive" ] && output="${output}
        $directive"
    done <<<"$(echo "$additional_directives" | jq -r '.[]')"

    output="${output}
}"
  done <<<"$(echo "$BLOCKS" | jq -c '.[]')"

  echo "$output"
}

generate_nginx_config_for_domain() {
  local domain="$1"
  local config_file="/etc/nginx/conf.d/${domain}.conf"

  cat <<EOF > "$config_file"
server {
    listen 80;
    server_name $domain;

EOF

  if [ "$ENABLE_HTTP_REDIRECT" = "true" ] && [ "$SECURE" = "true" ]; then
    echo "    return 301 https://\$host\$request_uri;" >> "$config_file"
  else
    echo "$(generate_location_blocks_for_domain "$domain" | sed 's/^/    /')" >> "$config_file"
  fi

  echo "}" >> "$config_file"

  if [ "$SECURE" = "true" ]; then
    cat <<EOF >> "$config_file"

server {
    listen 443 ssl;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

$(generate_location_blocks_for_domain "$domain" | sed 's/^/    /')
}
EOF
  fi

  log_info "Generated config for $domain at $config_file"
}

setup_ssl_certificates() {
  for domain in "${DOMAINS[@]}"; do
    domain_trimmed=$(echo "$domain" | xargs)
    cert_dir="/etc/letsencrypt/live/$domain_trimmed"
    cert_path="$cert_dir/fullchain.pem"

    if [ -f "$cert_path" ]; then
      cert_age=$(( $(date +%s) - $(stat -c %Y "$cert_path") ))
      if [ "$cert_age" -lt 86400 ]; then
        log_info "Certificate for $domain_trimmed is fresh. Skipping renewal."
        continue
      fi
    fi

    if [ "$SSL_PROVIDER" = "certbot" ]; then
      log_info "Generating cert with Certbot for $domain_trimmed"
      certbot certonly --standalone --preferred-challenges http \
        --email "$EMAIL" --agree-tos --no-eff-email -d "$domain_trimmed" || \
        log_error "Failed to generate cert for $domain_trimmed"
    elif [ "$SSL_PROVIDER" = "selfsigned" ]; then
      mkdir -p "$cert_dir"
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$cert_dir/privkey.pem" \
        -out "$cert_dir/fullchain.pem" \
        -subj "/CN=$domain_trimmed"
    else
      log_error "Unknown SSL provider: $SSL_PROVIDER"
    fi
  done

  echo "0 0 * * * certbot renew --pre-hook 'nginx -s stop' --post-hook 'nginx -s reload'" > /etc/crontabs/root
}

# Main
if [ "$SECURE" = "true" ]; then
  setup_ssl_certificates
fi

for domain in "${DOMAINS[@]}"; do
  domain_trimmed=$(echo "$domain" | xargs)
  generate_nginx_config_for_domain "$domain_trimmed"
done

log_info "Starting NGINX..."
exec nginx -g "daemon off;"

