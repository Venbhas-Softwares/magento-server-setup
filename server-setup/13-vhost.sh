# Module 13 — Create Nginx virtual host for Magento (runs as root during server setup)
#
# The Magento-specific routing rules live in ${MAGENTO_DIR}/nginx.conf, which is
# created by magento-deploy/06-vhost.sh (copies nginx.conf.sample → nginx.conf).
# The include line is commented out here so nginx -t passes before Magento is deployed.
#
# After running install-magento.sh:
#   1. Uncomment the include line in /etc/nginx/sites-available/${DOMAIN_NAME}
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
    set \$MAGE_MODE production;

    # Uncomment after Magento deployment (once nginx.conf.sample has been copied to nginx.conf):
    # include ${MAGENTO_DIR}/nginx.conf;
}
EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN_NAME}" "/etc/nginx/sites-enabled/${DOMAIN_NAME}"
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

print_message "Nginx vhost created: /etc/nginx/sites-available/${DOMAIN_NAME}"
print_warning "The Magento nginx.conf include is commented out until deployment is complete."
print_warning "After running install-magento.sh, uncomment the include line and reload Nginx."
