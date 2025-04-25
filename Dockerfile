FROM nginx:alpine

RUN apk add --no-cache jq openssl curl certbot certbot-nginx certbot-apache bash gettext nginx-mod-http-lua busybox-suid

COPY entrypoint.sh /entrypoint.sh
COPY renew-certs.sh /renew-certs.sh

RUN chmod +x /entrypoint.sh /renew-certs.sh

CMD ["/entrypoint.sh"]
