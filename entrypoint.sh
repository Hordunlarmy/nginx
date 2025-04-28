#!/bin/bash

set -e

log_info() {
	echo "[INFO] $1" >&2
}

log_error() {
	echo "[ERROR] $1" >&2
	exit 1
}

log_info "Starting entrypoint..."

[ -z "$DOMAIN_NAMES" ] && log_error "DOMAIN_NAMES is not set!"
[ -z "$SSL_PROVIDER" ] && log_error "SSL_PROVIDER is not set!"
[ -z "$EMAIL" ] && log_error "EMAIL is not set!"
[ -z "$SECURE" ] && log_error "SECURE is not set!"

PRIMARY_DOMAIN=$(echo "$DOMAIN_NAMES" | cut -d',' -f1)

generate_location_blocks() {
	if [ -z "$BLOCKS" ]; then
		log_info "BLOCKS is not set. No location blocks will be generated."
		echo ""
		return
	fi

	if ! echo "$BLOCKS" | jq -e '. | length > 0' >/dev/null 2>&1; then
		log_info "BLOCKS is empty or not valid JSON. No location blocks will be generated."
		echo ""
		return
	fi

	log_info "Generating NGINX location blocks..."
	local output=""

	while IFS= read -r block; do
		location=$(echo "$block" | jq -r '.location')
		address=$(echo "$block" | jq -r '.address')
		type=$(echo "$block" | jq -r '.type // "http"')
		rewrite=$(echo "$block" | jq -r '.rewrite // empty')

		address="${address//http:\/\//}"
		address="${address//https:\/\//}"

		if [ -z "$address" ]; then
			address="localhost"
		fi

		if [ "$location" = "/" ]; then
			has_root_location=true
		fi

		if [[ "$location" != "/" && "$location" != */ ]]; then
			location="${location}/"
		fi

		output="${output}
    location $location {"

		# Inject rewrite if specified
		if [ -n "$rewrite" ]; then
			output="${output}
        rewrite $rewrite;"
		fi

		if [ "$type" = "websocket" ]; then
			output="${output}
        proxy_http_version 1.1;
        proxy_pass http://$address;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_buffering off;
      "
		elif [ "$type" = "php" ]; then
			output="${output}
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass $address;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
      "
		else
			output="${output}
        proxy_pass http://$address;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
      "
		fi

		output="${output}
    }"
	done <<<"$(echo "$BLOCKS" | jq -c '.[]')"

	echo "$output" | sed 's/^/    /'
}

log_info "Generating HTTP blocks..."
HTTP_BLOCKS=$(generate_location_blocks)
log_info "Generated HTTP blocks successfully."

HTTPS_BLOCK=""

setup_ssl() {
	log_info "SECURE is true. Setting up SSL..."

	if [ "$SSL_PROVIDER" = "certbot" ]; then
		log_info "Using certbot to generate certificate..."

		mkdir -p /var/www/certbot

		DOMAIN_ARGS=""
		for DOMAIN in $(echo $DOMAIN_NAMES | tr ',' ' '); do
			DOMAIN_ARGS="$DOMAIN_ARGS -d $DOMAIN"
		done

		if ! certbot certonly --webroot -w /var/www/certbot \
			--email "$EMAIL" --agree-tos --no-eff-email $DOMAIN_ARGS; then
			log_error "Certbot certificate generation failed!"
		fi

		echo "0 0 * * * certbot renew --post-hook \"nginx -s reload\"" >/etc/crontabs/root

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

	local ssl_location_blocks=$(generate_location_blocks)

	HTTPS_BLOCK="server {
    listen 443 ssl;
    server_name ${DOMAIN_NAMES};

    ssl_certificate /etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
${ssl_location_blocks}
  }"
}

if [ "$SECURE" = "true" ]; then
	setup_ssl
fi

log_info "Rendering final nginx.conf..."

awk -v enable_http_redirect="$ENABLE_HTTP_REDIRECT" -v http_blocks="$HTTP_BLOCKS" -v https_block="$HTTPS_BLOCK" '
BEGIN {
    # Read all lines into the array
    in_block = 0;
    in_https_block = 0;
}
{
    if ($0 ~ "###BLOCKS###") {
        print "\t###BLOCKS###";
        # If HTTP redirect is enabled, add the redirect logic here
        if (enable_http_redirect == "true") {
            print "\treturn 301 https://\$host\$request_uri;";
        } else {
            # Otherwise, include the http_blocks
            if (http_blocks != "") {
                print http_blocks;
            }
        }
    }
    else if ($0 ~ "###HTTPS SERVER###") {
        if (https_block != "") {
            print https_block;
        } else {
            print "\t###HTTPS SERVER###";
        }
    }
    else {
        print $0;
    }
}
' /etc/nginx/nginx.conf.template >/etc/nginx/nginx.conf

log_info "NGINX configuration generated successfully."

log_info "Starting NGINX..."
exec nginx -g "daemon off;"
