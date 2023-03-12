#!/usr/bin/env bash
set -e
dnf install nginx -y
snipSelf="/etc/nginx/conf.d/self-signed.conf"
snipSsl="/etc/nginx/conf.d/ssl-params.conf"
defaultSite="/etc/nginx/conf.d/default.conf"
selfSignedKey="/etc/ssl/private/nginx-selfsigned.key"
selfSignedCrt="/etc/ssl/certs/nginx-selfsigned.crt"
mkdir -p /etc/ssl/private/

if [ ! -f $selfSignedCrt ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout $selfSignedKey \
        -out $selfSignedCrt \
        -subj "/C=CA/ST=BC/L=Vancouver/O=COMPANY NAME/CN=$HOSTNAME"
fi

if [ ! -f /etc/ssl/certs/dhparam.pem ]; then
    openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
fi

cat << EOF > $snipSelf
ssl_certificate /etc/ssl/certs/nginx-selfsigned.crt;
ssl_certificate_key /etc/ssl/private/nginx-selfsigned.key;
EOF

cat << EOF > $snipSsl
# from https://cipherli.st/
# and https://raymii.org/s/tutorials/Strong_SSL_Security_On_nginx.html

ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
ssl_prefer_server_ciphers on;
ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH";
ssl_ecdh_curve secp384r1;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
# Disable preloading HSTS for now.  You can use the commented out header line that includes
# the "preload" directive if you understand the implications.
#add_header Strict-Transport-Security "max-age=63072000; includeSubdomains; preload";
add_header Strict-Transport-Security "max-age=63072000; includeSubdomains";
add_header X-Frame-Options DENY;
add_header X-Content-Type-Options nosniff;

ssl_dhparam /etc/ssl/certs/dhparam.pem;
EOF


cat << EOF > $defaultSite
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name server_domain_or_IP;
    return 302 https://$server_name$request_uri;
}

server {

    # SSL configuration

    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    include conf.d/self-signed.conf;
    include conf.d/ssl-params.conf;
}
EOF

systemctl enable nginx --now