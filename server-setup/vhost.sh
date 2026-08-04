# Module vhost — Create Nginx virtual host for the web root (runs as root during server setup)
#
# This is a minimal placeholder vhost. The application's own nginx.conf (if it ships
# one, e.g. Magento) defines the actual routing/rewrite rules and is not created by
# this repo. Once an application is deployed to ${WEB_ROOT}:
#   1. Add `include ${WEB_ROOT}/nginx.conf;` inside the server block below (if the
#      application provides one — plain PHP apps, WordPress, and Drupal usually don't)
#   2. Run: nginx -t && systemctl reload nginx
#
# Uses: DOMAIN_NAME, WEB_ROOT, PHP_VERSION, VARNISH_ENABLED

# Port 80 is always the sole public HTTP entry point: Varnish owns it when enabled;
# otherwise this vhost binds it directly. Varnish, when present, sits in front on 80
# and proxies to this vhost on 8080 (see module: varnish).
if [[ "${VARNISH_ENABLED:-yes}" == "yes" ]]; then
    APP_VHOST_PORT=8080
else
    APP_VHOST_PORT=80
fi

print_step "Creating Nginx virtual host for '${DOMAIN_NAME}' (port ${APP_VHOST_PORT})..."

cat > "/etc/nginx/sites-available/${DOMAIN_NAME}" <<EOF
upstream fastcgi_backend {
    server unix:/run/php/php${PHP_VERSION}-fpm.sock;
}

server {
    listen ${APP_VHOST_PORT};
    server_name ${DOMAIN_NAME} www.${DOMAIN_NAME};

    set \$DOC_ROOT ${WEB_ROOT};

    # Add `include ${WEB_ROOT}/nginx.conf;` here once an application is deployed,
    # if the application ships its own Nginx rules (Magento does; most don't).
}
EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN_NAME}" "/etc/nginx/sites-enabled/${DOMAIN_NAME}"
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

print_message "Nginx vhost created: /etc/nginx/sites-available/${DOMAIN_NAME}"
print_warning "No application include is configured yet — add one after deploying your app."
