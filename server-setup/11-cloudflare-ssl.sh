# Module 11 — Nginx SSL termination for Cloudflare Full / Full (Strict) mode
#
# Adds an Nginx server block on port 443 that terminates TLS and proxies to
# Varnish on port 80. Also ensures PHP-FPM receives the X-Forwarded-Proto
# header so Magento can detect HTTPS via web/secure/offloader_header.
#
# Traffic flow after this module:
#   Cloudflare HTTPS → Nginx :443 (TLS) → Varnish :80 → Nginx :8080 → PHP-FPM
#
# Uses: DOMAIN_NAME

# ── Self-signed certificate ───────────────────────────────────────────────────
# Sufficient for Cloudflare Full mode — Cloudflare does not validate the origin
# certificate in Full mode. For Full (Strict), replace the cert and key with a
# Cloudflare Origin Certificate:
#   Cloudflare Dashboard → SSL/TLS → Origin Server → Create Certificate

print_step "Generating self-signed SSL certificate for Cloudflare Full mode..."
mkdir -p /etc/nginx/ssl

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/cloudflare.key \
    -out    /etc/nginx/ssl/cloudflare.crt \
    -subj   "/CN=${DOMAIN_NAME}/O=Magento/C=US"

chmod 600 /etc/nginx/ssl/cloudflare.key
chmod 644 /etc/nginx/ssl/cloudflare.crt
print_message "Certificate: /etc/nginx/ssl/cloudflare.crt (valid 10 years)"

# ── Nginx SSL terminator vhost ────────────────────────────────────────────────
# Proxies all HTTPS traffic to Varnish on localhost:80.
# Sets X-Forwarded-Proto: https so Varnish and Magento detect the original scheme.

print_step "Creating Nginx SSL terminator on port 443..."
cat > /etc/nginx/sites-available/cloudflare-ssl <<EOF
server {
    listen 443 ssl;
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};

    ssl_certificate     /etc/nginx/ssl/cloudflare.crt;
    ssl_certificate_key /etc/nginx/ssl/cloudflare.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    location / {
        proxy_pass            http://127.0.0.1:80;
        proxy_set_header      Host               \$host;
        proxy_set_header      X-Real-IP          \$remote_addr;
        proxy_set_header      X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto  https;
        proxy_read_timeout    600s;
        proxy_connect_timeout 600s;
        proxy_send_timeout    600s;
    }
}
EOF

ln -sf /etc/nginx/sites-available/cloudflare-ssl /etc/nginx/sites-enabled/

# ── FastCGI params — pass X-Forwarded-Proto to PHP-FPM ───────────────────────
# Magento's web/secure/offloader_header reads $_SERVER['HTTP_X_FORWARDED_PROTO'].
# The standard /etc/nginx/fastcgi_params does not include this header; add it once.

if ! grep -q "HTTP_X_FORWARDED_PROTO" /etc/nginx/fastcgi_params; then
    echo 'fastcgi_param  HTTP_X_FORWARDED_PROTO  $http_x_forwarded_proto;' \
        >> /etc/nginx/fastcgi_params
    print_message "Added HTTP_X_FORWARDED_PROTO to /etc/nginx/fastcgi_params"
fi

nginx -t
systemctl reload nginx

print_message "SSL terminator active: HTTPS :443 → Varnish :80 → Nginx :8080"
print_warning "For Cloudflare Full (Strict): replace /etc/nginx/ssl/cloudflare.crt"
print_warning "and cloudflare.key with a Cloudflare Origin Certificate."
