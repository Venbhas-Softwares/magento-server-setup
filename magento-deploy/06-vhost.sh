# Module 06 — Copy nginx.conf.sample to nginx.conf in the Magento docroot.
#
# The Nginx virtual host was created during server setup (server-setup/13-vhost.sh).
# The include line inside the vhost is commented out — after this module runs,
# a root user must uncomment it and reload Nginx:
#   sed -i 's/# include/include/' /etc/nginx/sites-available/${DOMAIN_NAME}
#   nginx -t && systemctl reload nginx
#
# Uses: MAGENTO_DIR

print_step "Checking for Nginx config in Magento docroot..."

if [[ -f "${MAGENTO_DIR}/nginx.conf" ]]; then
    print_message "nginx.conf already exists — using it as-is."
elif [[ -f "${MAGENTO_DIR}/nginx.conf.sample" ]]; then
    cp "${MAGENTO_DIR}/nginx.conf.sample" "${MAGENTO_DIR}/nginx.conf"
    print_message "Copied nginx.conf.sample → nginx.conf"
else
    print_error "Neither nginx.conf nor nginx.conf.sample found in ${MAGENTO_DIR}."
    print_message "Ensure the Magento repository was cloned correctly (module 02)."
    exit 1
fi

print_warning "ACTION REQUIRED (as root after deployment):"
print_warning "  Uncomment the include line in /etc/nginx/sites-available/${DOMAIN_NAME}"
print_warning "  Then run: nginx -t && systemctl reload nginx"
