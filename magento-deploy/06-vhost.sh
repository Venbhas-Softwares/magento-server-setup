# Module 02 — Create Nginx virtual host and reload Nginx.
# The server block delegates all Magento-specific routing rules to
# nginx.conf inside the docroot (Magento's own maintained config).
# If nginx.conf is absent, it is copied from nginx.conf.sample.
# Uses: DOMAIN_NAME, MAGENTO_DIR, PHP_VERSION

# ── Ensure nginx.conf exists in the Magento docroot ──────────────────────────

print_step "Checking for Nginx config in Magento docroot..."

if [[ -f "${MAGENTO_DIR}/nginx.conf" ]]; then
    print_message "nginx.conf already exists — using it as-is."
elif [[ -f "${MAGENTO_DIR}/nginx.conf.sample" ]]; then
    cp "${MAGENTO_DIR}/nginx.conf.sample" "${MAGENTO_DIR}/nginx.conf"
    print_message "Copied nginx.conf.sample → nginx.conf"
else
    print_error "Neither nginx.conf nor nginx.conf.sample found in ${MAGENTO_DIR}."
    print_message "Ensure the Magento repository was cloned correctly (module 03)."
    exit 1
fi

# ── Write the minimal server block ───────────────────────────────────────────

print_step "Creating Nginx virtual host for '${DOMAIN_NAME}' (port 8080)..."

cat > "/etc/nginx/sites-available/${DOMAIN_NAME}" <<NGINX_CONFIG
upstream fastcgi_backend {
    server unix:/run/php/php${PHP_VERSION}-fpm.sock;
}

server {
    listen 8080;
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};

    set \$MAGE_ROOT ${MAGENTO_DIR};
    set \$MAGE_MODE production;

    include ${MAGENTO_DIR}/nginx.conf;
}
NGINX_CONFIG

ln -sf "/etc/nginx/sites-available/${DOMAIN_NAME}" "/etc/nginx/sites-enabled/${DOMAIN_NAME}"
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

print_message "Nginx vhost created: /etc/nginx/sites-available/${DOMAIN_NAME}"
print_message "Magento Nginx config: ${MAGENTO_DIR}/nginx.conf"
