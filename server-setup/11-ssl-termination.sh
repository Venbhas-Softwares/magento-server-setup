# Module 11 — Nginx SSL termination (HTTPS :443 → Varnish :80)
#
# Optional module, controlled by ENABLE_SSL_TERMINATION in server-setup.conf.
# Skip it entirely when TLS is already terminated upstream of this server
# (Cloudflare "Flexible" mode, an external load balancer, another CDN) — in
# that case Varnish stays the sole HTTP-facing service on port 80.
#
# When enabled, this module either installs an operator-supplied certificate
# (SSL_CERT_PATH / SSL_KEY_PATH) or generates a self-signed one suitable for
# Cloudflare "Full" mode — Cloudflare does not validate the origin certificate
# in Full mode. For Full (Strict) or any provider that does validate the
# origin cert, set SSL_CERT_PATH/SSL_KEY_PATH to a real certificate (e.g. a
# Cloudflare Origin Certificate: Cloudflare Dashboard → SSL/TLS → Origin
# Server → Create Certificate).
#
# Adds an Nginx server block on port 443 that terminates TLS and proxies to
# Varnish on port 80. Also ensures PHP-FPM receives the X-Forwarded-Proto
# header so Magento can detect HTTPS via web/secure/offloader_header.
#
# Traffic flow when enabled:
#   Edge/CDN HTTPS → Nginx :443 (TLS) → Varnish :80 → Nginx :8080 → PHP-FPM
#
# Uses: DOMAIN_NAME, ENABLE_SSL_TERMINATION, SSL_CERT_PATH, SSL_KEY_PATH

if [[ "$ENABLE_SSL_TERMINATION" != "yes" ]]; then
    print_message "ENABLE_SSL_TERMINATION=no — skipping Nginx SSL termination. Varnish remains the sole HTTP-facing service on port 80."
    return 0
fi

# ── Certificate: operator-supplied or self-signed ─────────────────────────────

mkdir -p /etc/nginx/ssl

if [[ -n "$SSL_CERT_PATH" && -n "$SSL_KEY_PATH" ]]; then
    print_step "Installing operator-supplied SSL certificate..."
    cp "$SSL_CERT_PATH" /etc/nginx/ssl/cloudflare.crt
    cp "$SSL_KEY_PATH"  /etc/nginx/ssl/cloudflare.key
    print_message "Certificate installed from: $SSL_CERT_PATH"
else
    print_step "Generating self-signed SSL certificate for Cloudflare Full mode..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/cloudflare.key \
        -out    /etc/nginx/ssl/cloudflare.crt \
        -subj   "/CN=${DOMAIN_NAME}/O=Magento/C=US"
    print_message "Certificate: /etc/nginx/ssl/cloudflare.crt (valid 10 years)"
fi

chmod 600 /etc/nginx/ssl/cloudflare.key
chmod 644 /etc/nginx/ssl/cloudflare.crt

# ── Nginx SSL terminator vhost ────────────────────────────────────────────────
# Proxies all HTTPS traffic to Varnish on localhost:80.
# Sets X-Forwarded-Proto: https so Varnish and Magento detect the original scheme.

print_step "Creating Nginx SSL terminator on port 443..."
cat > /etc/nginx/sites-available/ssl-terminator <<EOF
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
        proxy_pass              http://127.0.0.1:80;
        proxy_set_header        Host               \$host;
        proxy_set_header        X-Real-IP          \$remote_addr;
        proxy_set_header        X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto  https;
        proxy_read_timeout      600s;
        proxy_connect_timeout   600s;
        proxy_send_timeout      600s;
        proxy_buffer_size       128k;
        proxy_buffers           4 256k;
        proxy_busy_buffers_size 256k;
    }
}
EOF

ln -sf /etc/nginx/sites-available/ssl-terminator /etc/nginx/sites-enabled/

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
if [[ -z "$SSL_CERT_PATH" ]]; then
    print_warning "Using a self-signed certificate — valid for Cloudflare Full mode only."
    print_warning "For Full (Strict) or another provider that validates the origin cert,"
    print_warning "set SSL_CERT_PATH/SSL_KEY_PATH in the config and re-run: --modules=11"
fi
