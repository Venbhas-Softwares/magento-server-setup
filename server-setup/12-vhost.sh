# Module 12 — Create Nginx virtual host for the web root (runs as root during server setup)
#
# This is a minimal placeholder vhost. Magento's own nginx.conf (shipped with the
# application) defines the actual routing/rewrite rules and is not created by this
# repo. Once an application is deployed to ${MAGENTO_DIR}:
#   1. Add `include ${MAGENTO_DIR}/nginx.conf;` inside the server block below
#   2. Run: nginx -t && systemctl reload nginx
#
# Uses: DOMAIN_NAME, MAGENTO_DIR, PHP_VERSION

print_step "Creating Nginx virtual host for '${DOMAIN_NAME}' (port 8080)..."

cat > "/etc/nginx/sites-available/${DOMAIN_NAME}" <<EOF
upstream fastcgi_backend {
    server unix:/run/php/php${PHP_VERSION}-fpm.sock;
}

server {
    listen 8080;
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};

    set \$MAGE_ROOT ${MAGENTO_DIR};

    # Add `include ${MAGENTO_DIR}/nginx.conf;` here once an application is deployed.
    # MAGE_MODE is app-specific and intentionally not set here — Magento's own
    # nginx.conf (or the deployment process) should define it.
}
EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN_NAME}" "/etc/nginx/sites-enabled/${DOMAIN_NAME}"
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

print_message "Nginx vhost created: /etc/nginx/sites-available/${DOMAIN_NAME}"
print_warning "No application include is configured yet — add one after deploying your app."
